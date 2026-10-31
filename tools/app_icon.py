# app_icon.py - the VX Mac Host icon's three visionOS layers (back.png opaque, middle.png, front.png, 1024x1024) and preview.png, written to the current directory; copy them into app/Assets.xcassets/AppIcon.solidimagestack/<Layer>.solidimagestacklayer/Content.imageset/
from PIL import Image, ImageDraw, ImageFilter
import math
S=1024; K=4; W=S*K
def up(c): return [(x*K,y*K) for x,y in c]
def save(img,name): img.resize((S,S),Image.LANCZOS).save(name)

# BACK: deep night gradient + perspective grid
back=Image.new('RGB',(W,W))
px=back.load()
for y in range(0,W,K):
    t=y/W
    for x in range(0,W,K):
        dx=(x/W-0.5); dy=(t-0.42)
        r=math.hypot(dx,dy)
        a=max(0,1-r*1.6)
        col=(int(10+40*a+30*t),int(8+10*a),int(30+70*a+20*(1-t)))
        for j in range(K):
            for i in range(K):
                px[x+i,y+j]=col
d=ImageDraw.Draw(back)
hz=int(W*0.60)
gc=(70,40,140)
for i in range(-12,13):
    x0=W/2+i*W*0.05; x1=W/2+i*W*0.35
    d.line([(x0,hz),(x1,W)],fill=gc,width=3*K)
yy=hz; step=W*0.012
while yy<W:
    d.line([(0,yy),(W,yy)],fill=gc,width=3*K); step*=1.35; yy+=step
glow=Image.new('RGB',(W,W),(0,0,0)); g=ImageDraw.Draw(glow)
g.rectangle([0,hz-6*K,W,hz+6*K],fill=(255,60,170))
glow=glow.filter(ImageFilter.GaussianBlur(30*K))
back=Image.blend(back,Image.composite(glow,back,glow.convert('L')),0.7)
save(back,'back.png')

# MIDDLE: neon visor ring (cyan->magenta)
mid=Image.new('RGBA',(W,W),(0,0,0,0)); m=ImageDraw.Draw(mid)
cx,cy,R=W/2,W*0.47,W*0.33
for k in range(360):
    a0=math.radians(k); t=(math.sin(a0)+1)/2
    col=(int(40+215*t),int(230-170*t),int(255-40*t),255)
    m.arc([cx-R,cy-R,cx+R,cy+R],k,k+1.5,fill=col,width=26*K)
blur=mid.filter(ImageFilter.GaussianBlur(22*K))
mid=Image.alpha_composite(blur,mid)
save(mid,'middle.png')

# FRONT: bold geometric "VX"
fr=Image.new('RGBA',(W,W),(0,0,0,0)); f=ImageDraw.Draw(fr)
s=W/1024
def P(pts): return [(x*s,y*s) for x,y in pts]
V=[(250,330),(330,330),(400,560),(470,330),(550,330),(440,690),(360,690)]
X1=[(540,330),(620,330),(790,690),(710,690)]
X2=[(710,330),(790,330),(620,690),(540,690)]
yellow=(255,236,40,255)
sh=Image.new('RGBA',(W,W),(0,0,0,0)); sd=ImageDraw.Draw(sh)
for poly in (V,X1,X2): sd.polygon(P([(x+10,y+14) for x,y in poly]),fill=(0,0,0,170))
sh=sh.filter(ImageFilter.GaussianBlur(10*K))
for poly in (V,X1,X2): f.polygon(P(poly),fill=yellow)
# cyan cut line through letters (cyber accent)
f.rectangle(P([(230,505),(810,519)]),fill=(0,0,0,0))
f.rectangle(P([(230,506),(810,518)]),fill=(40,240,255,255))
fr=Image.alpha_composite(sh,fr)
save(fr,'front.png')

# preview composite (circular mask like visionOS)
comp=Image.open('back.png').convert('RGBA')
for n in ('middle.png','front.png'): comp=Image.alpha_composite(comp,Image.open(n))
mask=Image.new('L',(S,S),0); ImageDraw.Draw(mask).ellipse([0,0,S-1,S-1],fill=255)
out=Image.new('RGBA',(S,S),(0,0,0,0)); out.paste(comp,(0,0),mask)
out.save('preview.png')
