"""꽉 찬 정사각형 원화를 macOS 아이콘 규격으로: 1024 캔버스, 824 연속 곡률 사각형(squircle), 은은한 그림자."""
import sys
from PIL import Image, ImageDraw, ImageFilter

src, out = sys.argv[1], sys.argv[2]
S, BOX, OFF = 1024, 824, 100
SS = 4  # 가장자리를 매끄럽게 하려고 4배로 그린 뒤 줄인다

art = Image.open(src).convert("RGBA").resize((BOX, BOX), Image.LANCZOS)

# 초타원(|x|^n + |y|^n = 1, n=5) — Apple 아이콘의 연속 곡률 모서리에 가깝다
n, big = 5.0, BOX * SS
pts = []
import math
for i in range(720):
    t = 2 * math.pi * i / 720
    c, s = math.cos(t), math.sin(t)
    x = math.copysign(abs(c) ** (2 / n), c)
    y = math.copysign(abs(s) ** (2 / n), s)
    pts.append(((x + 1) / 2 * (big - 1), (y + 1) / 2 * (big - 1)))
mask_big = Image.new("L", (big, big), 0)
ImageDraw.Draw(mask_big).polygon(pts, fill=255)
mask = mask_big.resize((BOX, BOX), Image.LANCZOS)

shape = Image.new("RGBA", (BOX, BOX), (0, 0, 0, 0))
shape.paste(art, (0, 0), mask)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh = Image.new("RGBA", (BOX, BOX), (0, 0, 0, 90))
shadow.paste(sh, (OFF, OFF + 12), mask)
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
canvas = Image.alpha_composite(canvas, shadow)
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
layer.paste(shape, (OFF, OFF), shape)
canvas = Image.alpha_composite(canvas, layer)
canvas.save(out)
print("saved", out)
