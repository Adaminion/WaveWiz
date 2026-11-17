#  2026-11-17
import struct, numpy as np
HDR=512
def frames(path):
    d=np.memmap(path,dtype=np.uint8,mode='r'); out=[]; p=0
    while p+HDR<=len(d):
        if bytes(d[p:p+12])!=b'WAVE HELLO!\n': break
        h=bytes(d[p:p+HDR])
        fh=dict(n=struct.unpack_from('<I',h,12)[0],
                flags=struct.unpack_from('<I',h,36)[0],
                w=struct.unpack_from('<H',h,40)[0],hgt=struct.unpack_from('<H',h,42)[0],
                q1=struct.unpack_from('<I',h,48)[0],q2=struct.unpack_from('<I',h,52)[0],
                addr=struct.unpack_from('<16I',h,64),size=struct.unpack_from('<16I',h,128),
                fifo=struct.unpack_from('<16H',h,192),off=p)
        out.append(fh); p+=HDR+sum(fh['size'])
    return d,out
def cs_slice(d,fh,i):
    s=fh['off']+HDR+sum(fh['size'][:i]); return d[s:s+fh['size'][i]]
