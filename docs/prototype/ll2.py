# 2026-11-17
import numpy as np
from kwv import *
from PIL import Image
def stream(d,fr,i):
    return np.concatenate([np.asarray(cs_slice(d,f,i)) for f in fr])
def starts(fr,i):
    s=[0]
    for f in fr: s.append(s[-1]+f['size'][i])
    return s
def read_bits(buf, bitpos, n, width=10):
    # vectorized read of n consecutive width-bit LSB-first values
    idx=bitpos+np.arange(n,dtype=np.int64)*width
    byte=idx>>3; sh=idx&7
    v=(buf[byte].astype(np.uint32)|(buf[byte+1].astype(np.uint32)<<8)|(buf[byte+2].astype(np.uint32)<<16))
    return (v>>sh)&((1<<width)-1)
def ll2(d,fr,k,pxd=3328,extra=0):
    f=fr[k]; w=f['w']>>3; h=f['hgt']>>3
    buf=stream(d,fr,0); st=starts(fr,0)
    bd=f['fifo'][0]+((f['flags']>>16)&1)*64
    b0=st[k]*8+bd+10*pxd+extra
    raw=read_bits(buf,b0,w*h*4)
    rows=raw.reshape(h,4*w)
    out=np.zeros((4,h,w),np.uint16)
    xs=np.arange(w); xsh=(xs+w-1)%w
    for c in range(4):
        xo=(xsh&3)|(((xsh>>6)&3)<<2)|(c<<4)|(((xsh>>2)&0xF)<<6)
        out[c]=rows[:,xo]
    return out
if __name__=='__main__':
    import sys
    d,fr=frames('/mnt/user-data/uploads/wave1113/c0042/f000009.kwv')
    k=int(sys.argv[1]) if len(sys.argv)>1 else 5
    o=ll2(d,fr,k).astype(np.float32)
    print('min/max per color',[(int(x.min()),int(x.max()),int(x.mean())) for x in o])
    tile=np.concatenate([np.concatenate([o[0],o[1]],1),np.concatenate([o[2],o[3]],1)],0)
    Image.fromarray(np.clip(tile/4,0,255).astype(np.uint8)).resize((tile.shape[1]*2,tile.shape[0]*2),Image.NEAREST).save(f'll2_fields_{k}.png')
    rgb=np.stack([o[0],(o[1]+o[2])/2,o[3]],-1)
    rgb=np.clip((rgb-rgb.min())/(np.percentile(rgb,99.5)-rgb.min()),0,1)**(1/2.2)
    Image.fromarray((rgb*255).astype(np.uint8)).resize((o.shape[2]*3,o.shape[1]*3),Image.BILINEAR).save(f'll2_rgb_{k}.png')
