//! Sideloads an IPA with the Increased Memory Limit turned on, which iloader has no option for, and exports the
//! certificate it signed with so LiveContainer's JIT-less mode can use the same one.
//! Usage: dockbox-install <file.ipa> [--no-memory] [--forget]

use idevice::usbmuxd::{UsbmuxdAddr, UsbmuxdConnection};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{certificates::DevelopmentCertificate, developer_session::DeveloperSession, teams::TeamsApi},
    sideload::{SideloaderBuilder, TeamSelection, builder::MaxCertsBehavior, cert_identity::CertificateIdentity},
    util::{callbacks::ExtensionsBehaviorCallbackBox, keyring_storage::KeyringStorage},
};
use std::{fs, io::{Read, Write}, os::unix::fs::PermissionsExt, path::PathBuf};

const STORAGE: &str = "dockbox-install";
const MACHINE: &str = "dockbox-install";

fn ask(prompt: &str) -> String {
    print!("{prompt}");
    std::io::stdout().flush().unwrap();
    let mut line = String::new();
    std::io::stdin().read_line(&mut line).unwrap();
    line.trim().to_string()
}

async fn two_factor(params: TwoFactorCallbackParams) -> Result<TwoFactorCallbackResponse, rootcause::Report> {
    if params.unknown {
        println!("That code method failed. Enter \"d\" to send a code to your devices.");
    }
    let code = ask("Enter the 6-digit Apple code (\"r\" resends it, \"d\" sends it to your devices): ");
    Ok(match code.as_str() {
        "d" => TwoFactorCallbackResponse::SendToDevices,
        "r" if !params.unknown => TwoFactorCallbackResponse::ResendCode,
        _ => TwoFactorCallbackResponse::SubmitCode(code),
    })
}

/// Only runs when Apple's limit on certificates is reached. Never revokes anything without a typed choice.
async fn choose_revoke(certs: Vec<DevelopmentCertificate>) -> Result<Option<Vec<String>>, rootcause::Report> {
    println!("\nThis Apple account has no free certificate slots. Revoking one can stop apps signed with it, including ones from iloader.");
    for (i, c) in certs.iter().enumerate() {
        println!("  {}: {} on {}", i + 1, c.name.as_deref().unwrap_or("Unnamed"), c.machine_name.as_deref().unwrap_or("unknown machine"));
    }
    let picks: Vec<String> = ask("Number to revoke, or Enter to cancel: ")
        .split(',')
        .filter_map(|s| s.trim().parse::<usize>().ok())
        .filter(|n| *n > 0 && *n <= certs.len())
        .filter_map(|n| certs[n - 1].serial_number.clone())
        .collect();
    Ok(if picks.is_empty() { None } else { Some(picks) })
}

fn random_password() -> String {
    let mut bytes = [0u8; 12];
    fs::File::open("/dev/urandom").unwrap().read_exact(&mut bytes).unwrap();
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(ipa) = args.iter().find(|a| !a.starts_with("--")).map(PathBuf::from) else {
        eprintln!("Usage: dockbox-install <file.ipa> [--no-memory] [--forget]");
        std::process::exit(2);
    };
    let more_memory = !args.iter().any(|a| a == "--no-memory");
    if args.iter().any(|a| a == "--forget") {
        if let Ok(entry) = keyring::Entry::new(STORAGE, "login") {
            let _ = entry.delete_credential();
        }
        println!("Forgot the saved Apple ID.");
    }
    if !ipa.is_file() {
        eprintln!("No file at {}", ipa.display());
        std::process::exit(2);
    }

    rustls::crypto::ring::default_provider().install_default().expect("crypto provider");
    isideload::init().expect("error reporting");

    let mut usbmuxd = UsbmuxdConnection::default().await.expect("Can't reach usbmuxd. Is it running?");
    let devices = usbmuxd.get_devices().await.expect("Can't list devices");
    let Some(device) = devices.first() else {
        eprintln!("No iPhone found. Plug it in and unlock it.");
        std::process::exit(1);
    };
    let provider = device.to_provider(UsbmuxdAddr::from_env_var().unwrap(), "dockbox-install");

    // Saved in this laptop's keyring after the first successful install, never in the app or on the phone.
    let saved = keyring::Entry::new(STORAGE, "login").and_then(|e| e.get_password()).ok().and_then(|s| {
        s.split_once('\n').map(|(e, p)| (e.to_string(), p.to_string()))
    });
    let (email, password) = saved.clone().unwrap_or_else(|| {
        (ask("Apple ID email: "), rpassword::prompt_password("Apple ID password: ").unwrap())
    });
    if saved.is_some() {
        println!("Using the saved Apple ID {email}. Run with --forget to clear it.");
    }
    let mut account = AppleAccount::builder(&email)
        .anisette_provider(RemoteV3AnisetteProvider::default().unwrap().set_serial_number("2".to_string()))
        .login(&password, two_factor)
        .await
        .expect("Apple sign-in failed");
    let mut session = DeveloperSession::from_account(&mut account).await.expect("Developer sign-in failed");

    let teams = session.list_teams().await.expect("Couldn't list developer teams");
    let team = teams.first().expect("This Apple ID has no developer team").clone();

    let storage = KeyringStorage::new(STORAGE.to_string());
    let behavior = MaxCertsBehavior::Prompt(choose_revoke);
    let identity = CertificateIdentity::retrieve(MACHINE, &email, &mut session, &team, &storage, &behavior)
        .await
        .expect("Couldn't get a signing certificate");

    let mut sideloader = SideloaderBuilder::<_, ExtensionsBehaviorCallbackBox>::new(session, email.clone())
        .team_selection(TeamSelection::First)
        .max_certs_behavior(behavior)
        .storage(Box::new(storage))
        .machine_name(MACHINE.to_string())
        .build();

    println!("Installing {}{} ...", ipa.display(), if more_memory { " with Increased Memory Limit" } else { "" });
    sideloader
        .install_app(&provider, ipa, more_memory, None::<fn(f32) -> std::future::Ready<()>>, None)
        .await
        .expect("Install failed");

    if let Ok(entry) = keyring::Entry::new(STORAGE, "login") {
        let _ = entry.set_password(&format!("{email}\n{password}"));
    }

    let cert_password = random_password();
    let p12 = identity.as_p12(&cert_password).await.expect("Couldn't export the certificate");
    let out = PathBuf::from(std::env::var("HOME").unwrap()).join("Downloads/dockbox-certificate.p12");
    fs::write(&out, p12).unwrap();
    fs::set_permissions(&out, fs::Permissions::from_mode(0o600)).unwrap();

    println!("\nInstalled.");
    println!("Certificate: {}", out.display());
    println!("Password:    {cert_password}");
    println!("Send that file to the phone, then in DockBox: Settings > Remove Certificate, then Import Certificate.");
    println!("Keep the file private, and delete it from Downloads afterwards. It can sign apps as your account.");
}
