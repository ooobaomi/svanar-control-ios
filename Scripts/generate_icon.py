"""Optional art regeneration. Requires Pillow; generated assets are committed."""
from pathlib import Path
from PIL import Image, ImageDraw
import json

root = Path(__file__).resolve().parents[1] / 'App' / 'Assets.xcassets'
icons = root / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
image = Image.new('RGB', (1024,1024), '#101719')
d = ImageDraw.Draw(image)
for x,y in [(310,360),(650,360)]:
    d.rounded_rectangle((x-90,y-130,x+90,y+100), radius=88, fill='#9ce5bb')
    d.rounded_rectangle((x-30,y+60,x+45,y+300), radius=35, fill='#9ce5bb')
    d.rounded_rectangle((x-42,y-62,x+42,y+26), radius=40, fill='#223937')
d.arc((205,200,810,830), 32,148, fill='#6c9f8a', width=15)
slots = [('iphone','20x20','2x'),('iphone','20x20','3x'),
         ('iphone','29x29','2x'),('iphone','29x29','3x'),
         ('iphone','40x40','2x'),('iphone','40x40','3x'),
         ('iphone','60x60','2x'),('iphone','60x60','3x'),
         ('ipad','20x20','1x'),('ipad','20x20','2x'),
         ('ipad','29x29','1x'),('ipad','29x29','2x'),
         ('ipad','40x40','1x'),('ipad','40x40','2x'),
         ('ipad','76x76','1x'),('ipad','76x76','2x'),
         ('ipad','83.5x83.5','2x'),('ios-marketing','1024x1024','1x')]
entries=[]
for idiom,size,scale in slots:
    pixels=round(float(size.split('x')[0])*int(scale[0]))
    name=f'icon-{pixels}.png'
    image.resize((pixels,pixels), Image.Resampling.LANCZOS).save(icons/name)
    entries.append({'idiom':idiom,'size':size,'scale':scale,'filename':name})
(icons/'Contents.json').write_text(json.dumps({'images':entries,'info':{'author':'xcode','version':1}},indent=2)+'\n')
(root/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}})+'\n')
print('Generated all iPhone/iPad icons')
