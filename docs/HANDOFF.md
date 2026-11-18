<!-- 2026-11-17 -->
# Wave Browser — project handoff

## Goal
Build a fast, stable desktop replacement for Freefly's **Wave Player** (Flutter desktop: macOS, Windows, Linux).
The owner has a Freefly Wave high-speed camera and uses it for his slow-motion channel. He grades and edits in other software, so this app does **not** need colour tools. The priorities are:
1. Browse clips fast and never crash. No auto-play when a clip is opened or a drive is plugged in.
2. Thumbnails, plus scrubbing through every frame.
3. **Trimmed offload**: copy only a frame range (in/out points) to disk in the camera-native format. Copying whole clips is usually pointless (they run to hundreds of GB).
4. Later: half-resolution and full-resolution decode, and export (image sequences / ProRes via ffmpeg).

House rule for code files: the first line is a date-stamp comment `// YYYY-MM-DD` (or appended at the end of line 1 if that line must be code). Update the stamp to today's date on every edit.

## Where the format comes from (important)
Wave started as Shane Colton's personal camera project; Freefly later commercialised it with his company Keiryou.
His original firmware and FPGA source is public under the **MIT licence**: https://github.com/coltonshane/WAVE-Vivado (last updated Nov 2021, unmaintained).
- `base_cmd.vitis/WAVE/src/frame.h`: clip and frame header structs. They match real 2026 files byte for byte.
- `base_cmd.vitis/WAVE/src/hdmi.c`, `hdmi_dark_frame.c`: how the preview decoder picks codestreams, bit-discard counts and LL2 pixel order.
- `base_cmd.srcs/sources_1/ip/HDMI_1.0/src/`: hardware **decoder** (`decoder_4x16.v`, `dequantizer_4x16.v`, `decompressor.v`, `idwt26_h2.v`, `idwt26_v2.v`, `clarke_inv.v`, `dark_frame.v`).
- `base_cmd.srcs/sources_1/ip/Encoder_1.0`, `Wavelet_S1_1.0`, `Wavelet_S2_1.0`: the encoder side, needed to work out the stage-1 (full-res) decode.
- Blog with the theory: http://scolton.blogspot.com/2019/10/real-time-wavelet-compression-for-high.html (2/6 wavelet = PyWavelets "rbio1.3", integer lifting).
MIT licence: commercial use and distribution are allowed. Keep Shane's copyright and licence notice in the app. Do not use Freefly/Wave branding; "works with Freefly Wave footage" is fine. A patent search has not been done yet.

## On-disk layout (camera SSD mounts read-only over USB)
```
/c0040/c0040.kwi          131,584 B   clip index / header + calibration tables
/c0040/f000000.kwv        ~1 GB       frame chunks, f000000..f0000NN
```
Sample footage on the owner's Mac: `/Users/adaminion/Movies/wave1113` (clips c0040–c0061).

### .kwi (clip file)
Starts with the 512 B `ClipHeader_s` (see frame.h): `"WAVE HELLO!\n"`, version, u16 w, u16 h, f32 fps, f32 shutterAngle, f32 colorTemp, gain, 5600K/3200K colour matrices, HDR kneepoints, CMV12000 sensor settings.
Seen: 2048×1024 @ 1548 fps, 2048×512 @ 2955, 2048×640 @ 2408; shutter 360/270; 5600 K.
After that: two big tables of int16 values (0x200–0xE205 and 0x10200–0x1E205), most likely dark-frame / fixed-pattern-noise calibration (dark rows/cols). Not decoded yet.

### .kwv (frame chunks)
A chunk is a run of frames. Each frame = 512 B `FrameHeader_s` + 16 codestream slices written back to back (cs0..cs15, each `csSize[i]` bytes). Next frame offset = off + 512 + sum(csSize). Frames are not split across chunks (to verify).
FrameHeader_s (little-endian), offsets:
- 0x00 char[12] "WAVE HELLO!\n"
- 0x0C u32 nFrame (frame number, increments by 1)
- 0x10 u32 nFrameBacklog
- 0x14 u64 tFrameRead_us (sensor read timestamp, µs; delta ≈ 1e6/fps)
- 0x1C u64 tFrameWrite_us
- 0x24 u32 csFIFOFlags (bits 16+i = extra 64-bit discard for codestream i)
- 0x28 u16 w, 0x2A u16 h
- 0x30 u32 q_mult_HH1_HL1_LH1 (hi16 = HH1, lo16 = LH1/HL1), 0x34 u32 q_mult_HH2_HL2_LH2
- 0x40 u32 csAddr[16] (camera RAM addresses; continuous: addr[k+1] = addr[k] + size[k])
- 0x80 u32 csSize[16]
- 0xC0 u16 csFIFOState[16]
- 0xE0 s8 tempPS, tempPL, tempCMV, tempSSD

**Codestreams are continuous across frames**: concatenating codestream i's slices from consecutive frames gives one continuous bitstream. A frame's data for stream i starts at (its slice start)*8 + bitDiscard_i bits, where bitDiscard_i = csFIFOState[i] + ((csFIFOFlags >> (16+i)) & 1) * 64. Some data for frame N therefore lives in frame N+1's slice, so decoding frame N needs frame N+1 (or the next chunk's first frame at chunk ends).

Codestream map (from hdmi.c): cs0 = LL2, cs1 = LH2, cs2 = HL2, cs3 = HH2. cs4..cs15 = stage 1 (HH1/HL1/LH1 × 4 colour fields; exact order to be derived from Encoder_1.0).

## Decoding status
- **LL2 (1/8 scale preview): working.** See `ll2.py` / `kwv.py` (Python + numpy prototype).
  - LL2 is raw packed 10-bit, LSB-first, not entropy-coded. Per row: 10 bits × 4 colours × wLL2 pixels; wLL2 = w>>3, hLL2 = h>>3.
  - Start bit = stream start of frame + bitDiscard_0 + 10 × pxDiscard, where pxDiscard = 3328 in 2K mode and 6336 in 4K mode.
  - Pixel order in a row (2K): xs = (x + wLL2 - 1) % wLL2; offset = xs[1:0] | xs[7:6]<<2 | colour<<4 | xs[5:2]<<6. For 4K, xs[8:7] and xs[6:2] (see bitOffsetInLL2 in hdmi_dark_frame.c).
  - The 4 colour fields are the Bayer channels (R, G1, G2, B per firmware naming; the TODO in the source says the order may not match the Bayer grid).
  - Verified on c0042: a correct image. The bottom row may be slightly off.
- **Half-res (LL1): working** (`lib/wave/ll1.dart`, verified on real 2K and 4K clips). LL1 is w/4 x h/4 per colour field (512x256 for 2048x1024, 1024x768 for 4096x3072).
  - cs1 = LH2, cs2 = HL2, cs3 = HH2: groups of 4 values with the VLC from `decoder_4x16.v` (prefix = trailing ones of the low byte: 0 ones -> all zero, 1 -> 2 bits, 2 -> 3, 3 -> 4, 4 -> 5, 5 -> 6, 6 -> 8, 7 -> 10, 8 -> 14; values two's complement, LSB-first after the prefix). Dequantise: out = (q * (65536 / q_mult) + (q < 0 ? 255 : 0)) >> 8, q_mult from frame header 0x34 (low 16 bits HL2/LH2, high 16 bits HH2).
  - Same row layout and start margin as LL2 (3328 values in 2K, 6336 in 4K; decode through them, do not skip). A margin 8 values off visibly breaks the picture, so the margin is exact for all four streams.
  - Reconstruction: vertical inverse on columns (LL2 + LH2 and HL2 + HH2), then horizontal inverse (L + H). Lifting: D' = D - ((S[n-1] - S[n+1] + 2) >> 2); Xeven = S - (D' >> 1); Xodd = Xeven + D'. Frame edges are clamped. Colour fields: R, G1, G2, B; neutral preview = R, (G1+G2)/2, B with gamma 2.2.
  - `lib/wave/video_export.dart` pipes LL1 frames into ffmpeg (H.264 mp4, one video per marked range).
- **Full-res**: needs the stage-1 streams; the decode has to be derived from the Encoder_1.0 + Wavelet_S1 Verilog. The vertical wavelet borrows rows from the previous frame (boundary rollover).
- Colour: apply the clip's colour matrix and the dark frame later. The owner grades elsewhere, so a neutral output is fine.

## Suggested app architecture
- Flutter UI. Native decoding (Rust or C via FFI, or Dart isolates for the LL2 preview since it's just bit unpacking). GPU shader later for full-res playback.
- Index chunks by scanning frame headers: read 512 B, jump by sum(csSize). Never read whole files.
- Trimmed offload = new folder with a rewritten .kwi + only the needed frames (+1 extra frame on each side for the continuous-stream/discard dependency). Check against Wave Player's own camera-native export (v1.3.0+) so the result opens in Wave Player.
