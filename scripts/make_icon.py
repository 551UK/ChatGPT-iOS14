#!/usr/bin/env python3
import math, struct, zlib, sys
from pathlib import Path

def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

def draw_icon(size, path):
    w = h = size
    pix = bytearray(w*h*4)
    bg = (32, 33, 35, 255)
    for y in range(h):
        for x in range(w):
            i=(y*w+x)*4; pix[i:i+4]=bytes(bg)
    cx=cy=size/2
    radius=size*0.235
    tube=max(2, int(size*0.048))
    centers=[]
    for k in range(6):
        a=math.radians(k*60-30)
        centers.append((cx+math.cos(a)*radius*0.72, cy+math.sin(a)*radius*0.72))
    for y in range(h):
        for x in range(w):
            hit=False
            for px,py in centers:
                d=math.hypot(x-px,y-py)
                if abs(d-radius*0.62) <= tube:
                    hit=True; break
            if hit:
                i=(y*w+x)*4; pix[i:i+4]=bytes((245,245,245,255))
    # dark center to keep the mark crisp
    for y in range(h):
        for x in range(w):
            if math.hypot(x-cx,y-cy) < radius*0.34:
                i=(y*w+x)*4; pix[i:i+4]=bytes(bg)
    raw=bytearray()
    stride=w*4
    for y in range(h): raw += b'\x00' + pix[y*stride:(y+1)*stride]
    data=b'\x89PNG\r\n\x1a\n'+png_chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+png_chunk(b'IDAT',zlib.compress(bytes(raw),9))+png_chunk(b'IEND',b'')
    Path(path).write_bytes(data)

def main(outdir):
    out=Path(outdir); out.mkdir(parents=True, exist_ok=True)
    draw_icon(60, out/'AppIcon60x60.png')
    draw_icon(120, out/'AppIcon60x60@2x.png')
    draw_icon(180, out/'AppIcon60x60@3x.png')

if __name__=='__main__': main(sys.argv[1])
