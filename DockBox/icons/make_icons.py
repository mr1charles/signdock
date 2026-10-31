#!/usr/bin/env python3
"""Draws the app icons into this folder. Run by hand when the design changes; the PNGs are committed."""
import pathlib
from PIL import Image, ImageDraw

here = pathlib.Path(__file__).parent
S = 1024

def gradient(top, bottom):
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        c = tuple(int(top[i] + (bottom[i] - top[i]) * y / S) for i in range(3))
        for x in range(S):
            px[x, y] = c
    return img

def box(img, ink, lid, flap):
    """A shipping box seen from above-front: an app in its container."""
    d = ImageDraw.Draw(img)
    d.polygon([(512, 190), (830, 340), (512, 490), (194, 340)], fill=lid)
    d.polygon([(194, 370), (497, 513), (497, 850), (194, 700)], fill=ink)
    d.polygon([(830, 370), (527, 513), (527, 850), (830, 700)], fill=flap)
    return img

def phones(img, outer, screen, inner):
    """A phone with a smaller phone on its screen."""
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((292, 130, 732, 894), 84, fill=outer)
    d.rounded_rectangle((322, 160, 702, 864), 58, fill=screen)
    d.rounded_rectangle((412, 300, 612, 690), 34, fill=outer)
    d.rounded_rectangle((430, 318, 594, 672), 20, fill=inner)
    return img

box(gradient((255, 149, 64), (232, 62, 90)), (255, 255, 255), (255, 236, 214), (255, 214, 190)).save(here / "dockbox.png")
box(gradient((58, 26, 34), (24, 12, 22)), (255, 149, 64), (255, 190, 130), (232, 96, 84)).save(here / "dockbox-dark.png")
box(Image.new("RGB", (S, S), (0, 0, 0)), (200, 200, 200), (255, 255, 255), (150, 150, 150)).save(here / "dockbox-tinted.png")
phones(gradient((44, 212, 170), (16, 118, 180)), (255, 255, 255), (12, 70, 96), (72, 224, 190)).save(here / "vphone.png")
phones(gradient((10, 44, 52), (6, 20, 34)), (72, 224, 190), (8, 30, 40), (255, 255, 255)).save(here / "vphone-dark.png")
phones(Image.new("RGB", (S, S), (0, 0, 0)), (255, 255, 255), (40, 40, 40), (200, 200, 200)).save(here / "vphone-tinted.png")
