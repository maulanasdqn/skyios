# iOS 16 on sweet (Redmi Note 10 Pro, SM7150) - working notes

## Agent handoff / active work (2026-11-19, latest; session 15 ended ~03:00 WIB)

### >>> HANDOFF 2026-11-20 (session 17): CoreAnimation on the GPU with compiled shaders <<<

**Observed (probe90, 2026-11-20 09:52):** backboardd renders the lock screen and the
whole home screen (icons, labels, dock, Search pill) through the Adreno 618, with
CoreAnimation's own shaders compiled offline; no hang, no wait failures, 0-13 skipped
draws per boot. The output matches the software-CA screenshots (the black wallpaper is
black in software CA too; the left circle is AssistiveTouch). `logs/shot-probe90-*.png`.

**Shader pipeline (tools/air-spec, commit 56cd3ac):** `airspec.py -O ca.ll:FUNC 'consts'`
specialises one QuartzCore metallib function (research/root/qc/ca.ll = metal-objdump of
default.metallib) for a function-constant set with the Metal toolchain's air-opt;
`air2glsl.py` translates the specialised AIR to GLSL; glslangValidator -> SPIR-V;
`skyprog` (mesa ir3 + port of gallium fd6_program.cc VS+FS state, built in docker image
skyios-mesadev via build-skyprog.sh, run in skyios-ir3c) emits ir3 code + a6xx program
registers + constant layout; `genprogs.py ca.ll skyios-metal/progs/keys.txt
skyios-metal/bundle/SkyPrograms.h` builds the table (51 of 53 seen pipelines; missing:
display_overdrive_lut_gen (3D texture), inplace_copy (texture write)). Keys come from the
driver log (`rec pipeline ...`, `rec noprog ...` for missing ones; constants sorted).
Facts found: CA vertex buffer = Metal buffer 1, stride 48 (float4 pos, float2 tc0/tc1,
half4 color); MVP = buffer 2; images at fragment texture 3+; blend_function 54 = no
shader blend (hardware blend from the pipeline); dest_count/blend 46/luma_boost read the
framebuffer -> emulated by a 2D-engine copy of the target (SkyRender.m fbCopy).

**Kernel slots:** SkyAdrenoAccel had 64 buffer slots per client; imports ran out (probe88/89
skipped most textured draws). Now 320 (0109 patch updated; kernel for probe90/91 =
ci-clean2 with SkyAdrenoAccel.cpp/SweetFramebuffer.cpp recompiled by the flags line of
localbuild/build60.log (path dxb->ci-clean2) and relinked with ci-clean2/build.log line
3579660; stripped kernels in the session scratchpad k90/k91).

**Frame rate (observed, probes 91-105):**
- 10.4 swaps/s came from a missing IOMFB property: QuartzCore paces itself from
  `IOMFBDisplayRefresh` {displayMinRefreshInterval, displayRefreshStepMachTime} (mach time).
  Kernel patch 0117 publishes it (16.667 ms) -> probe92: 39 swaps/s. (backboardd never
  enables vsync notifications, selector 72 = EnableNotifications per the dyld cache's
  IOMobileFramebuffer; no async selectors are used.)
- 0117 also adds SkyAdrenoAccel selector 7: submit flushing the allocations + only the listed
  surfaces (flushAll cleaned every imported surface on every submit and wait) -> 54 swaps/s.
- Driver: per-pipeline program cache, CP3D_STATE/program regs as pre-packed packets, no per-draw
  debug, small completion-gated allocation pool (<=1 MiB entries, 8 MiB; an unbounded pool ran the
  128 MiB GPU address space out -> imports kIOReturnNoSpace -> skipped draws, broken pictures in
  probe94/97), render targets flushed once. perf counters (`perf 600 commits` log line).
- **probe104 (current correct state, commit 7e08f7f): lock + home screen correct, 51-54
  swaps/s, ~625 us per draw of which ~5.4 ms per commit is the framebuffer-fetch scratch
  (fresh 11 MB allocation per command buffer).** probe100 (scratch shared by all frames):
  60.0 swaps/s, 74 us per draw, backboardd ~65% CPU, but the lock screen clock/date text was
  missing; probe103 (scratch reused through the gated pool): text missing too. probe105 (shared
  scratch zero-filled by the 2D engine before the copy): text present; probe106 (zero scratch,
  no copy): black screen, 59.5 swaps/s, 80 us/draw, backboardd ~48% -> the copy is needed and
  works for full-screen targets; probe107 (shared scratch + GRAS_A2D_SCISSOR set to the full
  target): 60.0 swaps/s, home screen correct, lock screen clock text missing again. **Open
  problem:** why reused scratch memory loses the lock text (offscreen targets of other sizes?
  stale TP cache?). Code is back to the probe104 scratch (fresh per command buffer, correct,
  ~52 fps).
- **Lead from HakiOS (oosexgang/hakios-xnu-kernel, docs/reference/metal.md, hakios-metal/src
  render.cpp:1586-1612, MIT):** their sysmem framebuffer-fetch barrier is WFI, PC_CCU_FLUSH_COLOR_TS
  **waited for with CP_WAIT_REG_MEM**, CACHE_INVALIDATE, WFI. fbCopy fired the flush events without
  waiting (a WFI does not wait for them). Guess: the fetch read the reused scratch before the copy
  reached memory. Uncommitted-to-device change (this session): `ccu_flush_wait()` around the copy +
  scratch shared by all frames again -> image `shim-boot-probe111.img` (k109, probe109 cmdline,
  sweetshot_crop=1), **not booted yet** (phone was on the daily image). Check: lock clock text
  present + ~60 swaps/s => fixed; text missing => revert fbCopy's scratch to per command buffer.
- skyprog: ir3 gives a sampler prefetch the texture index as its sampler; ported HakiOS's
  fixPrefetchSamplers (commit 7e9a730). Only display_overdrive_srgb_sampler changed (tex1 was read
  through the linear sampler instead of nearest). Their other finding (dsx.f16 returns the y
  derivative) does not apply here: air2glsl emits half as 32-bit float.
- Pixelation report: the user later said they probably misread it ("salah liat"); probe109/110
  full-res crops are sharp. Closed.
- **Wallpaper black on the GPU path (probe109/110 shots, lock + home):** backboardd skipped every
  draw of an ASTC_4x4_LDR (fmt 204) image (`draw skipped: texture slot 0 (metal 3) fmt 204`, skyp29/
  skyp30). Wallpaper worked in software CA (daily3, 2026-11-16). Commit 43d9f08 adds ASTC 4x4
  (FMT6_ASTC_4x4 0xc1, block-row pitch, block surfaces, bytes-no-copy and buffer->texture uploads,
  new one-time logs `buffer texture fmt`, `bytes texture fmt`, `blit buffer->texture fmt` to see
  which path CA uses). probe111 image rebuilt with it (+ the CCU wait); not booted yet.
- **probe111a-114 (2026-11-20 21:00-21:28, observed):** 111a (GPU, ASTC, shared scratch + CCU
  wait): no skipped draws (ASTC via `buffer texture fmt 204` and `bytes texture fmt 204 120x120`),
  lock clock text missing again -> scratch back to per command buffer (7b0ce3b); home wallpaper
  black. 112 (+ `sweetautobahn=1`): iOS 16 poster lock screen (date above clock), wallpaper black,
  clock dark grey, ~55 swaps/s (fb copy 6.5 ms/commit). 113 (same, software CA): wallpaper black too,
  clock red (vibrancy colour from the poster) -> **not a GPU driver problem**. 114 (no sweetaccel):
  backboardd draws nothing (console text) -> the accelerator is required. daily3 (2026-11-16, user
  saw the wallpaper) had `sweetautobahn=1`, kernel build69, no sweetaccel. Open: why the poster image
  never reaches the screen; asked the user whether their wallpaper is red-dominant.
- **probe115-119 (2026-11-20 22:54-23:25):** 115 = payload-daily3 (build69, its cmdline) + reboot/shots:
  wallpaper black too (user, shot) and touch dead -> not a kernel/GPU regression. 116 (k109, GPU,
  `posterwall fsprobe`): `/var/mobile/Library/SpringBoard` had NO LockBackground.cpbitmap /
  OriginalLockBackground.cpbitmap / thumbnails; complete backup in `SpringBoard.sweet-legacy-wallpaper/89`.
  117 (`posterwall restore`, new mode = inject's file copy only): all 4 files restored (observed).
  Wallpaper after restore not yet seen (needs the next boot).
  **Settings glitch (user photos, 116/117):** SMMU fault far 0x0 at a fence -> GPU present disabled,
  all draws skipped afterwards (ghosted / stale layers). Cause: the 128 MiB user IOVA window was
  full (105 MiB live, peak 124 MiB; ~5 full-screen 11 MB surfaces) -> map returned 0. Kernel
  cpuser.rs USER_L3 64 -> 256 (512 MiB). probe118 (k118) panicked: "Invalid kernel stack pointer"
  in backboardd (the 16 KiB bitmap + L3 array went through the stack in user open) -> both moved
  to statics, kernel k119 (scratchpad), image `shim-boot-probe119.img`, NOT booted yet: the phone
  hung on the probe118 panic screen (no USB), needs a manual reset.
- **probe119 (k119, 23:26, observed):** boots, "up to 512 MiB", no panic. User in Settings ->
  Accessibility -> Motion: page transition frozen with the old page visible (photo; shots 0-3).
  SMMU fault far 0x0 fsynr 0x2 again (fence 1193->1196, ib1 rem 81703) -> GPU present disabled,
  BUT only 78 MiB live (peak 120) -> **the IOVA window was NOT the cause** (the 512 MiB change is
  harmless, kept). Also `GPU present failed after 567 frames` before it. Wait-timeout log shows
  cp mark 0 / done mark 0 (marks unreadable?). Suspects, unverified: an address-0 operand in some
  packet (fbCopy's CP_WAIT_REG_MEM from 12c4140, a texture/buffer with iova 0), formats 550
  (BGRA10_XR) and the "no program" fbfetch variants are skipped, not causes. Next: route every
  emitted GPU address through a checked helper (log the site, drop the command buffer instead of
  faulting), and boot without the CCU waits to bisect.
- **Real cause of the far-0 SMMU faults (observed):** `sky_alloc FAILED` right before each fault:
  probe116 kIOReturnNoSpace (IOVA, fixed by 512 MiB), probe119 kIOReturnNoResources = the 320
  buffer slots per client full (320 live maps at the fault). `upload:` then returned 0 and the
  texture/sampler tables were loaded from gpu 0. Fixes: 696f5af (skip the draw when upload fails,
  1 MiB upload chunks, index buffer 0 check) -> probe120: no fault, allocations still failing
  (106 CA 64 KiB buffers + 14 full-screen surfaces = 320); xnu 0118 (4ee080a) 2048 slots, table
  IOMalloc'd -> kernel k121 (ci-clean2 + SkyAdrenoAccel.cpp recompiled, Rust lib with 512 MiB).
- **probe121 (k121 + bundle 696f5af, 23:50, observed):** no SMMU fault, no sky_alloc failure, no
  "no upload memory"; only 37 skipped draws (fmt 550 BGRA10_XR); 52-54 swaps/s. User: opening
  Control Center "freezes, touch does nothing": the GT9896 stopped sending frames right after the
  CC swipe (`SWEET TOUCH` frames stuck at 212 from 2000 to 20000 polls, 0 errors); rendering kept
  going. Same IC silence as the 0100s long-press (early-gpu.md), now for the whole boot. Next:
  touch watchdog (no frame for N s -> GT9896 reset via TLMM + re-init), then the CC blur
  (pixelated, "no program" fbfetch blend_function=54 variants) and format 550.
- **probe122-124 + daily image (2026-11-21 00:01-00:20, observed):**
  - 122 (k122 = k121 + xnu 0119 touch quiet reset): the reset fires after 3 s of silence and
    frames resume each time (72 -> 159 -> 244 -> 513 -> 818). **User: wallpaper works** (after the
    posterwall restore of probe117).
  - 123 (+ c37ed59: 31 more CA programs, 82 of 86 compile; color_opcodes arrays unsupported):
    no fault, 19 skipped draws (fmt 550/554), "no program" 53 (was thousands). But
    `GPU present failed after 5001 frames` -> CPU present for the rest of the boot.
  - Cause: sweet_rs_gpu_blit/compose returned false when a user submission held BUSY, and one
    failure disabled the GPU present. 2947b36: spin for BUSY (as sweet_rs_gpu_wait) + xnu 0120
    (off only after 8 failures in a row). 124 (k124): no fault, 0 skipped, no present failure,
    ~57 swaps/s all boot. Touch 0 frames (probe ok; probably not touched).
  - **Daily image rebuilt:** `skyios-shim/out/shim-boot-skyios-gpu.img` = k124 (scratchpad) +
    bundle of c37ed59 in the ramdisk + the old daily cmdline + `sweetautobahn=1` (no reboot/sims/
    shots). Previous one kept in the session scratchpad.
- **Touch still flaky on the daily (user, 2026-11-21 00:50), live log via the old usbnet process
  (pid 74260 since Nov 19, writes logs/live-skyios-daily-1119.txt; no reboot needed):** after an
  unlock swipe the IC sent no frame for minutes; 3 s/30 s resets did not bring it back then.
  xnu 0121 (k125): the watchdog logs PID/head/INT. probe125 (10 min): PID always "9896", head all
  0, INT high, SE idle -> **the IC is alive and simply reports nothing**; the controller is fine.
  15 of 42 touches ended by the 120 ms stale release (the IC often sends no lift frame).
  After 1635 frames no more frames for 7 min (not known whether the user still touched).
  Daily image rebuilt with k125 (01:13). Render: 52-57 swaps/s while animating; the gap to 60 is
  probably the per-commit framebuffer-fetch copy (~6.5 ms) + scratch allocation (~5 ms CPU).
- **60 fps (probe126, 2026-11-21 01:27, observed):** f04f1aa = fbfetch scratch shared by all
  frames (static, per size), CACHE_INVALIDATE before the copy (it was missing: the copy reads
  the target through the TP) and a 2D zero fill of the scratch before the copy (probe105 kept
  the lock text that way). perf: fb 18 us/commit (was 5.5 ms), draw 0.9 ms/commit, commit
  2.3 ms, gap 17.9 ms -> **300 swaps per 5 s = 60.0** all boot, no fault. Lock clock text NOT
  verified (shots show home/app switcher); daily image rebuilt with this bundle (01:34) for
  the user to check. If the text is missing: bisect fill vs invalidate.
  - Still open: formats 550/554 (BGRA10_XR, 19 draws), 2 programs with color_opcodes arrays, the
    fbfetch scratch reuse (lock clock text), the user asked for an iOS upgrade after stabilising.
- **`skyios-shim/out/shim-boot-skyios-gpu.img`** (2026-11-20 12:40): daily cmdline (no auto
  reboot, no sims) + `sweetmetal_procs=skyios-accel-test,backboardd` + kernel k93 + bundle of
  commit d668d2f: CoreAnimation on the GPU for normal use. Booted and left running.
  `shim-boot-skyios-daily.img` is still the software-CA fallback.
- Kernel images for these probes: ci-clean2 + local recompiles (scratchpad k93 = 0109 slots 320
  + 0117). Recompile one file: flags line from localbuild/build60.log (dxb->ci-clean2), relink
  with ci-clean2/build.log line 3579660, `xcrun strip -x`.
- Boot flakiness (observed): some boots stop at console text (probe91a, 103a) and some write
  only 2 SWEETLOG flushes (96, 101, 104a); re-running the same image works.

### >>> HANDOFF 2026-11-19 (session 15): clean local build, probe66 <<<

**Probes 54-65 are unreliable** (previous session, not recorded here before):
they were built with incremental local builds in `research/localbuild/dxb`,
and `touch` does not trigger recompiles. By that session's own finding,
probes 54-61 ran an unchanged kernel. The source tree there also has
uncommitted debug hacks (RGB fill, CPU-only copy). Its SWEETLOG reads were
stale (wrong offset/old data), so none of their "results" count.

**CI run 44316130996 (8f1d13f, 0067 `_cnputc` mute)** first failed because
the runner never started (GitHub capacity, not a patch error). It was re-run.

**Clean local build flow (mirrors `.github/workflows/xnu.yml`):**
1. `git clone research/localbuild/dxb research/localbuild/ci-clean`, checkout DXB_SHA 663906528d
2. copy `xnu/patches/*.patch *.sh` into `ci-clean/patches/`, apply the same `ARCHS` sed as CI
3. `SWEET_RUST_LIB=<skyios-kernel/build.sh output> MACOS_VERSION=13.5 KERNEL_CONFIG=DEVELOPMENT MACHINE_CONFIG=SWEET MAKEFLAGS=-k bash build.sh` (~25 min)
4. Only the 4 expected upstream patches are skipped; `sweet_console_muted` is checked in `_cnputc`
5. `xcrun strip -x`, then `target/release/skyios mkpayload KERNEL skyios-shim/out/sweet-0081hi.adt OUT --cmdline "<probe53 cmdline>" --ramdisk dtb/boot_unpacked/ramdisk`, then `skyios-shim/build.sh`

`sweet-0081hi.adt` has NO embedded boot-args (checked with strings), so the
"stale ADT args" theory below is wrong. Stale args came from elsewhere (NVRAM?).

**probe66** = clean local build of HEAD 8f1d13f with probe53's cmdline + ADT.
Booted 2026-11-19 00:0x. Result: console text only, no SWEETLOG or screenshot written
(log-pull still returns probe53's 301208-byte / flush #11 data; the 4 shot slots
are blank and stale, from an old sweetshot=90 boot).

**Root cause of "console text" since probe54 (observation from the user's photo):**
the console wraps, so the newest lines are at the TOP. The last printed line is
`SWEET ACCEL: SkyAdrenoMetalAccel (IOAcceleratorES) registered`. In the good
probe53 log the next line is from the battery driver. Re-booting the old
probe53 image now stalls at the SAME line, so this is phone state, not the kernel.
The kernel never reaches sweet_ufs_init, so there is no root mount, GUI or log.
Guess (unconfirmed): `SweetBattery::start` -> `sweet_i2c1_init()` (topaz QUP0
SE1 I2C) hangs on an unclocked register read, possibly after an OrangeFox/Linux boot.
`userdata` = journaled HFSX at partition offset 1024 (unmounted bit clear = dirty).

**probe67** = probe66 kernel + `sweetbattery=0` (skips i2c1 init and SPMI). Result:
boots fully into userspace (launchd, SpringBoard, backboardd) -> **the battery
start (topaz `sweet_i2c1_init`) is what hangs the boot**. But the log says
`SWEET GPU: no usable GMU firmware in this kernel (0 bytes)`, and backboardd sits
idle. **CI kernels never carry GPU firmware.** probe51 was a LOCAL build with fw,
not a CI kernel as stated below.

**Firmware must be embedded when building the Rust lib** (files in research/gpu-fw, kept out of git):
`F=$PWD/research/gpu-fw; SWEET_GMU_FW=$F/a618_gmu.bin SWEET_SQE_FW=$F/a630_sqe.fw SWEET_ZAP_MDT=$F/a615_zap.mdt SWEET_ZAP_B02=$F/a615_zap.b02 TOOLCHAIN=nightly-2026-07-28 skyios-kernel/build.sh`
Then relink only: run line 3579661 of `research/localbuild/ci-clean/build.log` (the clang++ link)
from `ci-clean/build/xnu.obj/DEVELOPMENT_ARM64_SWEET`, then `xcrun strip -x kernel.development.sweet.unstripped`.

**probe68** = probe67 + GPU firmware. GMU stages A-D OK, SQE 0x19a loaded,
backboardd swaps 1125x2436 surfaces and they are presented (one GPU present timed out,
"CPU copy from now on"; CPU copy ~2 ms/frame). The sweetshot at 180 s was written.

**Live log:** `target/release/skyios usbnet logs/live-NAME.txt` (sets up en8 192.168.7.1 + udp/5140).
An old `skyios usbnet --timeout 180 ...` (the tool takes only LOGFILE) had been writing
to a file named `--timeout`; it was moved to logs/live-usbnet-nov18.txt.
**Hands-free cycle:** `sweetreboot=300` resets with the IMEM bootloader reason; then boot
recovery/recovery.img, `skyios log-pull`, `skyios shot-pull`, `adb reboot bootloader`.

**probe69/70 (Metal bundle via tool container, commit ef10d29):** surface-less
RGBA8 textures now get IOSurfaces. Imports work until the GPU engine dies:
user submit seq 15 -> `SMMU fault far 0x528000 fsr 0x402`, CP hangs (status
0x00800005), `idle failed ... GPU present disabled`, engine `dead`. After that every
`sweet_rs_gpu_user_map` returns 0 -> import `0xe00002db` (kIOReturnNoSpace).
**The black GPU-rendered frame is caused by this hang, not by the IOVA space** (33 of 128 MiB used).
seq 15 held one prog=4 draw (ca_fixed solid, MVP). Source of 0x528000 is unknown (all
user buffer addresses come from iova). Also fixed: INDEX_SIZE (16-bit indices were sent
as 8-bit, commit dad34c7). Not yet booted with that fix.

**Deploying the Metal bundle:** `skyios-metal/bundle/build.sh OUT`, then
`skyios mktool tool.bin /System/Library/Extensions/SkyAdrenoMetal.bundle/ .../_CodeSignature/ B/SkyAdrenoMetal=D/SkyAdrenoMetal B/Info.plist=D/Info.plist B/_CodeSignature/CodeResources=D/_CodeSignature/CodeResources`,
and pass it as `mkpayload --ramdisk tool.bin` (installed after root mount, overwrites; persists on disk).
`dtb/boot_unpacked/ramdisk` is just the old Android ramdisk (no tools).

**probe71** (`sweetmetal_procs=skyios-accel-test`, so CA uses its software renderer): swaps
7/s then idle, but the 150-210 s screenshots are black. The display goes on/off (auto-lock).
Boot 0113t (Nov 16) DID capture the home screen with `sweetpowersim=110
sweetpowersim_every=20 sweetunlocksim=200 sweetshot=120 sweetshot_every=55`.
**probe72** = probe71 + that recipe, sweetwifi removed. **Result (observed, screenshots):
LOCK SCREEN at 120 s (`logs/shot-probe72-0.png`), HOME SCREEN after the unlock sim at
180 s (`logs/shot-probe72-2.png`).** Earlier black shots were the auto-locked display.
**Working image: `skyios-shim/out/shim-boot-probe72.img`** (kernel k68 = clean build +
GPU firmware, `sweetbattery=0`, CA software renderer, CPU present). Rate is software-bound
(~6-7 swaps/s when animating), so 60 fps needs the Metal path (GPU hang above).

**Hands-free cycle (no button presses):** `fastboot boot IMG`; `sweetreboot=300` resets into
OrangeFox recovery; wait ~30 s after adb shows `recovery` before `skyios log-pull` /
`shot-pull` (by-name links appear late); `adb reboot bootloader`.

**GPU (Metal) path for backboardd: bugs fixed this session (all committed):**
1. ef10d29 surface-less RGBA8 textures get IOSurfaces; replaceRegion/getBytes/blit copy implemented.
2. dad34c7 INDEX_SIZE: 16-bit indices were sent as 8-bit.
3. 0147e03 **CP_LOAD_STATE6 sampler/texture headers**: count was put in STATE_TYPE -> header
   0x00528000 (the old "FAR 0x528000"), CP fault + hang, engine dead. Now matches cp3d.rs.
4. d4c50e7 bound buffers/textures/index buffers are retained by the command buffer (Metal semantics).
5. dfe0977 buffer-backed textures retain their MTLBuffer; non-RGBA8 buffer textures not sampled.
6. f17123d user-open wait spins on CNTVCT (delay(100 ms) never returned in probe75).
Debug aids: kernel logs `ib1/ib2 base+rem` on a present timeout and `user unmap` events; the bundle
dumps user IBs 48-64 (`IB seq iova+off: words`).

**Current GPU blocker (probe78/79, no SMMU fault):** CP hangs at fence 56->57, status 0x00d70585,
ib1 rem 1782 in IB 57 (2345 dwords, 4 indexed draws, first pass renders to the 1125x2436 surface
at 0xc0018000, later passes to 64x64 targets). IB 49/51 with the same kind of draws completed.
IB 55 was lost (UDP). Not yet known what stalls; the prefetch position is near the first draw (dword 578).
Bisect probe80 (refusing to render into texture-owned surfaces) made backboardd stall: inconclusive, reverted.
Next ideas: dump IB 55 (it ran just before), check CCU/blit state left by the earlier pass, try
`CP_SET_DRAW_STATE`/WFI between passes, compare against freedreno's sysmem pass setup.

**GPU CP hang SOLVED (session 16, 2026-11-19, observed):** per-draw progress markers (commit 1611cf1:
CP_MEM_WRITE at CODE_PROG + CCU-flush timestamp at CODE_DONE, logged as `wait seq N failed: cp mark ..
done mark ..`) showed the hanging draw: probe84 draw 75 / probe85 draw 77 = CA's framebuffer-fetch
blend program (CODE_FS_BLEND, samples the render target as tex1) drawing into a freshly cleared 64x64
offscreen target (fbfetch into the 1125x2436 surface worked). The earlier "IB 57" reading was wrong
(ib1 rem is the prefetch position). Fix 77c2d45: those pipelines use CODE_FS_TEX + RB blend
ONE/ONE_MINUS_SRC_ALPHA (PROG_TEX_OVER). **probe86: no hang, GPU present stays on all boot**
(GPU present ~2 ms, 10-11 swaps/s while animating). Also: WFI between draws of one pass (2c4bb39,
not the cause), FS constant load dropped (its length was the whole 256 KiB buffer).
**But the output is wrong** (`logs/shot-probe86-*.png`: flat blue skewed quads on black): 447
`draw skipped` lines, i.e. most CA textured draws are dropped: no texture bound at idx 0 (CA binds
idx >= 1), A8/RG8 (fmt 1/30) textures rejected, buffer textures with bpr not a multiple of 64 (784),
std_vert*/downsample_blur/narrow_blur/luma_boost pipelines unmapped (prog -1 / 0). Solid fills use
CODE_FS_WHITE (ignore CA's colour) and their transform looks wrong. The Metal bundle maps CA's
pipelines onto 5 hand-written shaders; correct output needs: CA's vertex layouts (vertex_layout=,
texcoord_count0/1), colour/opacity from the fragment buffer, texture index binding, A8/RG8/R16 formats,
unaligned pitches (copy or TEX_CONST pitch alignment), and blur/effects (can be skipped first).
Images: `shim-boot-probe86.img` (backboardd on Metal), daily image unchanged (software CA).

**Console text race (observed):** the SAME image (probe81) once showed console text at 120-210 s
while backboardd presented ~10 swaps/s (CA showing its snapshot of the panel = console text), and
on a re-run (probe81b) showed the lock screen (120 s) and home screen (180 s). Fix (commit 44b86f5,
not yet booted): 0067b mutes `vcputc_options` itself; 0116 mutes + clears the panel when backboardd
asks for the layer default surface (before CA snapshots it). Clean build of these in
`research/localbuild/ci-clean2` (same flow as ci-clean).

**Images:**
- `skyios-shim/out/shim-boot-skyios-daily.img` = kernel from `research/localbuild/ci-clean2` (all
  patches incl. 0067b/0116, GPU firmware) + latest bundle, software CA, battery off, NO
  auto-reboot/sims: for normal use (`fastboot boot`). Booted at ~03:35 WIB 2026-11-19 and left running.
- `skyios-shim/out/shim-boot-probe82.img` = same kernel + `sweetreboot=300`, power/unlock sims and
  shots. Booted twice: **82a lock screen (120 s) + home screen (180 s); 82b lock screen at all 4 shots**
  (the unlock sim did not land); no console text in either -> 0116 fixes the race (observed 2/2).

**WLAN:** the thread logs the crypto self-test, then stops before `SMMU identity for SID`
(hangs in Mmio::map / apps-SMMU SMR writes in `radio_init_heap`). Even past that, WCN3990
firmware is loaded by the modem's WLFW QMI service (QRTR over GLINK/SMEM), and there is
no modem (MSS PIL) bring-up yet. WiFi needs that subsystem first.

**User goal now:** visible lock screen at 60fps + WiFi working.

### Older (2026-11-18)

### >>> HANDOFF 2026-11-18 (session 11): SMMU stall-on-fault fix, probe49 built <<<

**Goal:** Get GPU rendering at 60fps. Previous blockers (blr crash, sleep) solved.
Current blocker: SMMU fault at fence 59 kills GPU present permanently.

**Root cause 3 — SMMU stall-on-fault (SOLVED, committed c2e3f38):**
- SCTLR CFCFG=1 (bit 5) in `mem_setup()` caused the SMMU to STALL GPU transactions
  on translation faults instead of aborting. When a user IB referenced a bad address
  (FAR=0x1400000528000, FSR=0x402), the SMMU stalled the transaction, the CP hung,
  the fence never arrived, `idle()` timed out at 1s, and `dead=true` was set permanently.
- **Fix:** Clear CFCFG (bit 5) in SCTLR write → terminate/abort mode. GPU gets DECERR
  for bad addresses, draws complete with garbage, CP continues. Added `fault_count`
  tracking and `check_clear_smmu_fault()` method to detect, log, and W1C-clear faults.
  Rewrote `idle()` to check/clear fault after success, retry once on timeout before
  setting dead=true.
- **Files changed (committed):** `skyios-kernel/src/cp.rs`
  - `mem_setup()`: SCTLR from `(1<<6)|(1<<5)|(1<<2)|(1<<1)|1` to `(1<<6)|(1<<2)|(1<<1)|1`
  - `Engine` struct: added `fault_count: u32`
  - New method `check_clear_smmu_fault()` — reads FSR/FAR/FSYNR, logs, W1C clears FSR
  - Rewrote `idle()` — checks fault after success, retries once on timeout
- **Commit:** c2e3f38 "kernel: fix SMMU stall-on-fault killing GPU after user IB faults"

**Bad texture address investigation (ongoing):**
- FAR=0x1400000528000 → FAR_HI=0x00014000, FAR_LO=0x00528000
- For 32-bit IOVA space (T0SZ=32), FAR_HI should be zero. GPU generated a >32-bit address.
- Likely from a texture descriptor: TEX_CONST_4=0x00528000 (bare buffer offset without
  0xC0000000 IOVA base), TEX_CONST_5 bits[0:16] contain garbage 0x4000.
- SkyRender.m's `textureDescriptor` and `resolveTexGpu` look correct for valid paths.
  Draw path skips when desc=0 or prog invalid. The fault may come from a race or
  uninitialized descriptor reaching the GPU before the skip check.
- With SMMU abort mode, these faults are no longer fatal — just logged.

**Local build flow (re-link only, ~2 seconds):**
1. `TOOLCHAIN=nightly-2026-07-28 skyios-kernel/build.sh` → builds Rust lib
2. Run the linker command from the build directory (see session transcript or
   `research/localbuild/build10.log` line 1865) pointing to new Rust lib
3. `xcrun strip -x` the unstripped kernel
4. `skyios mkpayload KERNEL ADT OUT --cmdline "..." --ramdisk dtb/boot_unpacked/ramdisk`
5. `skyios-shim/build.sh PAYLOAD OUT.img`

**Boot images:**
- `skyios-shim/out/shim-boot-probe48.img` — blr+sleep fixes, NO SMMU fix
- `skyios-shim/out/shim-boot-probe49.img` — blr+sleep+SMMU fixes (NEW)
- Args: `sweetgpu=5 sweetgpu_delay=20 sweetaccel=2 sweetmetal_procs=skyios-accel-test,backboardd sweetdyldvars=1 sweetinsert=SpringBoard:/usr/lib/skyios/SkyPBFix.dylib sweetwifi=1 sweetbattery=1 sweetreboot=120 sweetshot=90`

**CI build status:**
- **Run 44227242600 (509da77, SUCCESS):** All patches applied, kernel linked
  successfully. All 4 previously-undefined symbols resolved:
  sweet_rs_init (0x...92288), sweet_rs_spawn_id (0x...92554),
  sweet_rs_kalloc (0x...9283c), sweet_sta_init (0x...fabe0).
  Artifact downloaded, probe50 boot image built.
  **probe50 = CI kernel with all C fixes (id-dispatch, 3s busy-wait,
  tsleep, SMMU abort, WLAN stubs) + Rust GPU driver.**
- **Run 44225287511 (38fe45c, FAILED):** 0093a SKIPPED — bsd/conf/files
  hunk failed at line 108 (context didn't account for 0072's additions).
  0115 iokit hunk now works (sweet_sta_init resolved). Still had 3
  undefined symbols from 0093a skip.
- **Run 44222102669 (9e5ed71, FAILED):** 4 undefined linker symbols.
- **Commits this session (12-14):**
  - 509da77: Fixed 0093a bsd/conf/files hunk context (session 14)
  - 38fe45c: Fixed 0115 iokit hunk line number (24→23) (session 13)
  - 3260445: Added 0093a patch + fixed 0115 iokit context (session 13)
  - 0699bf9: Updated handoff with CI session 12 progress
  - 9e5ed71: Fixed 0115 line counts (session 12)
  - 661cbaf: Restored 0062 documentation comments (session 12)
  - 1df973a: Fixed 0062 diff structure (session 12)
  - 2217cc7: Fixed RUST_TOOLCHAIN (session 12)
- Remaining skipped dxb patches (expected, not ours): iobuffermemd_monterey,
  skywalk_sonoma, syntax_checker_sonoma, TrustCache (files already exist).
- **SnapMetal research (session 11):** Studied the MIT-licensed Metal driver at
  github.com/Snapintosh/SnapMetal. Key findings for our 60fps target:
  - Uses IOGPU framework for submission (vs our custom IOKit user client)
  - Per-draw state emission is much richer: LRZ, bindless descriptors,
    framebuffer-fetch barriers, driver constants, 48+ register groups
  - Has proper IB packaging with kext-side relocation patching
  - CA renderer test (harness/ca-renderer.m) captures command streams, not pixels
  - Targets A8XX (Adreno X2-90), not directly applicable to our A6XX registers

**Phone state:** Booting probe53 (or in fastboot for next boot).
Boot command: `fastboot boot skyios-shim/out/shim-boot-probe53.img`

**Probe history (continued from session 10):**
| Probe | Test | Boot note | Result |
|-------|------|-----------|--------|
| probe48 | 3s busy-wait + full dispatch | **(not booted)** | — |
| probe49 | +SMMU stall-on-fault fix | **(READY, local build)** | — |
| probe50 | CI kernel, cpus=1 | Booted but console text covers screen, too slow | Console only |
| probe51 | CI kernel, cpus=8 | **BOOT SUCCESS** — log confirms backboardd, 15 GPU presents, lock screen behind console text | GPU works, console covers GUI |
| probe52 | Fresh ADT, gpu_delay=10 | ADT missing props, boot stalls early | Failed |
| probe53 | Original ADT, reboot=300, no kprintf_spam | **(READY)** | — |

**probe51 boot results (logs/boot-probe51.txt, 4503 lines):**
- 8/8 CPUs alive, L3 1459 MHz, silver 1.8 GHz, gold 2.3 GHz
- Battery: PM6150 100% 4453mV, external=1 charging=0 (POWER_PATH fix works)
- GPU: Adreno 618 @ 430 MHz, 15 GPU presents, 0/64 bad pixels, ~2.1ms/frame
- Metal: backboardd connected, CA render passes at 1125×2436
- WLAN: thread started, crypto selftest OK, but radio_init_heap silent (no "radio initialized" or "radio init failed")
- USB: DWC3 up, ECM gadget did not connect to host
- All prog=3 textured draws skipped (desc=0, texture descriptor empty)
- Console text stayed on screen because GPU delay was 60s (from ADT stale args) and user rebooted before presents cleared it

**Key issue: stale ADT boot-args override cmdline.** The `sweet-0081hi.adt`
contains `sweetgpu_delay=60 sweettop=5 sweetautobahn=1` etc. that
`PE_parse_boot_argn` finds first. Cmdline args come after. Need to
strip stale boot-args from the ADT or make mkpayload put cmdline first.

**Previous fixes (sessions 9-10, committed):**
- blr crash → ID-based dispatch (commit 402151b)
- sleep blocks forever → 3s busy-wait at thread start (commit 402151b)
- Battery stuck-charging → POWER_PATH cross-check (commit 899cbb5)

**Next concrete actions:**
1. ~~Fix CI patches~~ — DONE
2. ~~Build + boot CI kernel~~ — DONE (probe51 confirmed working)
3. Fix stale ADT boot-args (strip or rebuild sweet-0081hi.adt without embedded args)
4. Boot probe53 and wait full 2-3 min for lock screen to appear
5. Get USB Ethernet working for live log capture
6. Debug prog=3 texture descriptor (desc=0 → all textured draws skipped)
7. Debug WLAN radio_init_heap hang (passes crypto selftest, then silent)
8. Implement GPU memory free path (zero frees currently — resource leak)
