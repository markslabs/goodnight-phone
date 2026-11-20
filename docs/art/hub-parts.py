"""Pictures of the three bedroom hub parts for the website's /beacon page, in the guide's style.

Writes website/public/assets/part-board.svg, part-adapter.svg and part-cube.svg (240x180 each,
transparent, meant for a cream tile). Run: python3 docs/art/hub-parts.py
Drawings, not product photos: Amazon's images can't be hotlinked outside its own widgets.
"""
import importlib.util
import pathlib

here = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("scenes", here / "guide-scenes.py")
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)
INK, WHITE, METAL, SW = sc.INK, sc.WHITE, sc.METAL, sc.SW


def svg(body, label):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 180" width="240" height="180" '
            f'role="img" aria-label="{label}">{body}</svg>\n')


def cube(x, y, s=1.0):
    """The HONIZER outlet cube, three-quarter view: two sockets on the front, USB-C ports on the side."""
    return (f'<g transform="translate({x},{y}) scale({s})">'
            f'<path d="M30,-36 l18,-12 v72 l-18,12 z" fill="#E8E1D2" stroke="{INK}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<path d="M-30,-36 l18,-12 h60 l-18,12 z" fill="#F1EBDF" stroke="{INK}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<rect x="-30" y="-36" width="60" height="72" rx="6" fill="{WHITE}" stroke="{INK}" stroke-width="{SW}"/>'
            f'<rect x="-14" y="-24" width="3" height="11" fill="{INK}"/><rect x="11" y="-24" width="3" height="11" fill="{INK}"/>'
            f'<rect x="-14" y="10" width="3" height="11" fill="{INK}"/><rect x="11" y="10" width="3" height="11" fill="{INK}"/>'
            f'<rect x="36" y="-22" width="6" height="13" rx="3" fill="{INK}"/><rect x="36" y="2" width="6" height="13" rx="3" fill="{INK}"/></g>')


PARTS = {
    "part-board": (sc.board(120, 90, 2.0), "The Seeed XIAO ESP32-C6 board, about the size of a thumbnail"),
    "part-adapter": (sc.adapter(120, 90, 3.2), "A straight USB-C male-to-male adapter"),
    "part-cube": (cube(110, 96, 1.45), "A white outlet cube with USB-C ports on its side"),
}

if __name__ == "__main__":
    out = here.parent.parent / "website/public/assets"
    for name, (body, label) in PARTS.items():
        (out / f"{name}.svg").write_text(svg(body, label))
    print("\n".join(PARTS))
