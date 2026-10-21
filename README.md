![](https://boltgolt.nl/howdy/banner.png)

<p align="center">
	<a href="https://github.com/boltgolt/howdy/releases">
		<img src="https://img.shields.io/github/release/boltgolt/howdy.svg?colorB=4c1">
	</a>
	<a href="https://github.com/boltgolt/howdy/graphs/contributors">
		<img src="https://img.shields.io/github/contributors/boltgolt/howdy.svg?style=flat">
	</a>
	<a href="https://www.buymeacoffee.com/boltgolt">
		<img src="https://img.shields.io/badge/endpoint.svg?url=https://boltgolt.nl/howdy/shield.json">
	</a>
	<a href="https://actions-badge.atrox.dev/boltgolt/howdy/goto?ref=beta">
		<img src="https://img.shields.io/endpoint.svg?url=https%3A%2F%2Factions-badge.atrox.dev%2Fboltgolt%2Fhowdy%2Fbadge%3Fref%3Dbeta&style=flat&label=build&logo=none">
	</a>
	<a href="https://aur.archlinux.org/packages/howdy">
		<img src="https://img.shields.io/aur/votes/howdy?color=4c1&label=aur%20votes">
	</a>
</p>

Howdy provides Windows Hello™ style authentication for Linux. Use your built-in IR emitters and camera in combination with facial recognition to prove who you are.

Using the central authentication system (PAM), this works everywhere you would otherwise need your password: Login, lock screen, sudo, su, etc.

**NOTE:** This repository is a fork of [boltgolt/howdy](https://github.com/boltgolt/howdy). See [Fork changes vs. upstream](#fork-changes-vs-upstream) for everything that is different here, and keep in mind that upstream troubleshooting guides may not always apply.

## Fork changes vs. upstream

This fork was built for a machine with an **AMD iGPU** (Radeon 610M), where upstream's dlib pipeline cannot use CUDA and is slow on the CPU. The two big changes compared to upstream are hardware accelerated face recognition and guided multi-pose face enrollment. The dlib pipeline upstream ships is still present and remains the default; everything below activates it with `use_dnn = true`.

### 1. Hardware accelerated face recognition (`dnn_recognition.py`, new)

Upstream uses dlib (HOG or CNN detector + ResNet encoder, CPU only). This fork adds a second pipeline built on OpenCV's DNN module using the official [OpenCV Zoo](https://github.com/opencv/opencv_zoo) models:

- **YuNet** (`face_detection_yunet_2023mar.onnx`, 233 KB) — face detector
- **SFace** (`face_recognition_sface_2021dec.onnx`, 37 MB) — face recognizer

Measured on the target machine (320x240 frame, face in view): the dlib pipeline takes ~49 ms per frame, this pipeline ~17 ms. The networks run on the backend selected in the config:

```ini
[core]
use_dnn = true          # switch from dlib to the DNN pipeline
dnn_backend = opencl    # cpu | opencl (AMD/Intel/NVIDIA) | vulkan (experimental) | cuda
dnn_target = auto       # auto | cpu | cpu_fp16 | opencl | opencl_fp16 | vulkan | cuda | cuda_fp16
dnn_certainty = 0.637   # cosine distance threshold used by the DNN pipeline (lower = stricter)
```

Details that differ from the dlib path:

- Matching uses the **cosine distance** (`1 - dot`) over **unit-normalized encodings**. OpenCV builds SFace features unnormalized; the recognizer normalizes on load so stale or hand-edited models still compare correctly.
- Every encoding row is mapped back to the model owning it (`model_indexes`); upstream assumed exactly one encoding per model when printing the winning model label, which crashes once a model holds multiple encodings.
- Models stamp their enrollment method (`"type": "sface"` / `"dlib"`). Authentication filters the model file by the active method, because dlib and SFace encodings are mathematically incompatible — with mismatched models you get a clear re-enroll message instead of silent failure.
- Backend init performs a **warmup forward pass**, because some backends only fail on first inference. Broken backends fall back to the CPU with a printed warning (for example, Vulkan is incomplete in OpenCV 4.13 as packaged by Fedora and never engages; it stays selectable for other distros).
- Before any OpenCL use, the process sets `OPENCV_DNN_OPENCL_ALLOW_ALL_DEVICES=1` and `RUSTICL_ENABLE=radeonsi`, so AMD GPUs exposed through Mesa's Rusticl (which reports a non-GPU device type and is hidden by default in Fedora's Mesa) actually run the networks. Works as root, i.e. in the real PAM path.

The model files are not downloaded by a source build. After installing from source, run:

```sh
cd /usr/share/howdy-dnn   # or the configured dnn_data_dir
sudo ./install.sh
```

(Pre-built release rpms ship the models already — no download needed.)

### 2. Guided multi-pose enrollment (`cli/add.py`)

Upstream's `howdy add` captures a single frontal frame. When DNN mode is on (and `add_poses = true`, the default), a single `howdy add` run now:

1. Captures **3 frontal frames** and averages their landmark geometry into a neutral baseline
2. Prompts you to turn **left, right, tilt up, tilt down**, capturing up to 3 frames per direction, each gated against that baseline (yaw/pitch normalized by the eye-to-eye distance)
3. Stores every capture as a separate encoding in the model's `data` list — recognition then works from angles further off-center

Landmark points are derived geometrically per frame (sorted top-to-bottom into eyes / nose / mouth) so the gate works identically for the dlib and YuNet landmark orders, which are not interchangeable. Per-direction steps time out after 10 s and are skipped with a notice — enrollment never aborts because one direction failed. Sensitivity lives in `MIN_TURN` / `MIN_TILT` in `cli/add.py`, disable with `add_poses = false`.

The same prompt-driven loop is used by the dlib pipeline, where it also fixes an `np.ndarray` truthiness bug when YuNet-style results (which return `None` instead of an empty list for "no faces") flow through the multiple-face checks.

### 3. Build and packaging changes

- New meson option `dnn_data_dir` (default `${datadir}/howdy-dnn`) plus the install targets for `dnn-data/`
- New source files: `howdy/src/dnn_recognition.py`, `howdy/src/dnn-data/{install.sh,Readme.md}`
- README documents both features and how to enable them

### Compatibility notes

- Existing face models enrolled with dlib remain valid while `use_dnn = false`
- After enabling `use_dnn`, every user must run `sudo howdy add` again (the prompt-driven capture stores the new SFace encodings alongside old models in the same file, which is safe — only compatible models are loaded)
- `rubberstamps` (liveness checks) still use dlib; in DNN mode their dlib models are initialized lazily only after a successful recognition, so the fast path is unaffected

## Installation

### Quick install (pre-built release for Fedora)

The [releases page](https://github.com/Byte-256/howdy/releases) publishes a pre-built **rpm** for Fedora that includes everything out of the box (all-in-one): the compiled PAM module + CLI, the YuNet/SFace recognition models **shipped inside the package** (no first-run downloads), a default `config.ini` with hardware acceleration (`use_dnn = true`) and the same system layout as the COPR package it replaces:

```sh
# download the rpm for your architecture from the latest release and install:
curl -fLO https://github.com/Byte-256/howdy/releases/download/v3.1.0-fork.1/howdy-3.1.0-1.fc44.x86_64.rpm
sudo dnf install ./howdy-3.1.0-1.fc44.x86_64.rpm
```

(`dnf` resolves the runtime dependencies — `python3-opencv`, `python3-numpy` — automatically; `mesa-libOpenCL` is recommended for the OpenCL GPU backend and `python3-dlib` if you want the legacy dlib pipeline.)

Next steps after install: `sudo howdy config` (set `device_path`, e.g. `/dev/video0`), then `sudo howdy add` for guided multi-pose enrollment. The post-install flow (downloading the two onnx models) is only needed when installing from source without this rpm — run `sudo /usr/share/howdy-dnn/install.sh` then.

An experimental all-in-one **portable tarball** (bundled Python runtime + OpenCV, no distro dependencies, for other distributions) is also supported by `scripts/build-aio.sh` + the root `install.sh` bootstrap; assets are built on demand and may appear on the releases page alongside the rpm.

### From source

Howdy is currently available and packaged for Debian/Ubuntu, Arch Linux, Fedora and openSUSE. If you're interested in packaging Howdy for your distro, don't hesitate to open an issue.

**Note:** The build of dlib can hang on 100% for over a minute, give it time.

### Ubuntu or Linux Mint

Run the installer by pasting (`ctrl+shift+V`) the following commands into the terminal one at a time:

```
sudo add-apt-repository ppa:boltgolt/howdy
sudo apt update
sudo apt install howdy
```

This will guide you through the installation.

### Debian

Download the .deb file from the [Releases page](https://github.com/boltgolt/howdy/releases) and install with gdebi.

### Arch Linux

_Maintainer wanted._

Install the `howdy` package from the AUR. For AUR installation instructions, take a look at this [wiki page](https://wiki.archlinux.org/index.php/Arch_User_Repository#Installing_packages).

You will need to do some additional configuration steps. Please read the [ArchWiki entry](https://wiki.archlinux.org/index.php/Howdy) for more information.

### Fedora

_Maintainer: [@luyatshimbalanga](https://github.com/luyatshimbalanga)_

The `howdy` package is available as a [Fedora COPR repository](https://copr.fedorainfracloud.org/coprs/principis/howdy/), install it by simply executing the following commands in a terminal:

```
sudo dnf copr enable principis/howdy
sudo dnf --refresh install howdy
```

*Note:* Fedora 41 [removed support for Python2](https://fedoraproject.org/wiki/Changes/RetirePython2.7), but at this point in time Howdy still depends on it. If the install fails, you can fix this by installing the beta Repository and removing the release version:

```
sudo dnf copr remove principis/howdy
sudo dnf copr enable principis/howdy-beta
sudo dnf --refresh install howdy
```

See the link to the COPR repository for detailed configuration steps.

### openSUSE

_Maintainer: [@dmafanasyev](https://github.com/dmafanasyev)_

Go to the [openSUSE wiki page](https://en.opensuse.org/SDB:Facial_authentication) for detailed installation instructions.

### Building from source

If you want to build Howdy from source, a few dependencies are required.

#### Dependencies

- Python 3.6 or higher
  * pip
  * setuptools
  * wheel
- meson version 0.64 or higher
- ninja
- INIReader (can be pulled from git automatically if not found)
- libevdev

To install them on Debian/Ubuntu for example:

```
sudo apt-get update && sudo apt-get install -y \
python3 python3-pip python3-setuptools python3-wheel \
cmake make build-essential \
libpam0g-dev libinih-dev libevdev-dev python3-opencv \
python3-dev libopencv-dev
```

#### Build

```sh
meson setup build
meson compile -C build
```

You can also install Howdy to your system with `meson install -C build`.

## Setup

After installation, Howdy needs to learn what you look like so it can recognise you later. Run `sudo howdy add` to add a face model.

If nothing went wrong we should be able to run sudo by just showing your face. Open a new terminal and run `sudo -i` to see it in action. Please check [this wiki page](https://github.com/boltgolt/howdy/wiki/Common-issues) if you're experiencing problems or [search](https://github.com/boltgolt/howdy/issues) for similar issues.

If you're curious you can run `sudo howdy config` to open the central config file and see the options Howdy has to offer. On most systems this will open the nano editor, where you have to press `ctrl`+`x` to save your changes.

## Hardware accelerated face recognition

Howdy can use OpenCV's DNN module (the tiny YuNet detector + SFace recognizer) instead of dlib for face detection and identification. This pipeline is around 3x faster and the networks can run on the GPU, this is configured in the config file:

```ini
[core]
use_dnn = true
dnn_backend = opencl
dnn_target = auto
dnn_certainty = 0.637
```

The models are downloaded separately:
```sh
cd /usr/share/howdy-dnn # or the configured data directory
sudo ./install.sh
```

Backends: `cpu`, `opencl` (AMD/Intel/NVIDIA GPUs), `vulkan` (experimental) and `cuda` (NVIDIA). If the selected backend doesn't work, Howdy automatically falls back on the CPU.

Note: face models enrolled with dlib are not compatible with this pipeline. After enabling `use_dnn`, every user has to run `sudo howdy add` again.

## Multi-pose enrollment

`howdy add` does not use a single frame anymore: it first captures your face from the front and then asks you to turn your head left, right, up and down, storing separate encodings for every head pose in a single model. This makes recognition work even when your head isn't perfectly aligned at login.

The extra poses can be disabled with `add_poses = false` in the `[core]` config section, and the turn/tilt sensitivity can be tuned with the `MIN_TURN` and `MIN_TILT` constants in `cli/add.py`.

## Credits and model licenses

Howdy is a fork of [boltgolt/howdy](https://github.com/boltgolt/howdy) (MIT license).

The hardware accelerated pipeline bundles the recognition models so no download is needed at runtime:

| Model | Role | License | Author(s) |
|---|---|---|---|
| [YuNet](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet) (`face_detection_yunet_2023mar.onnx`) | face detection | MIT | Shiqi Yu (bi) via [OpenCV Zoo](https://github.com/opencv/opencv_zoo) |
| [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) (`face_recognition_sface_2021dec.onnx`) | face recognition | Apache-2.0 | OpenCV / OpenCV Zoo |

Both licenses are permissive and allow redistribution; the full license texts are in `howdy/src/dnn-data/Readme.md` and in the opencv_zoo repository.

The optional dlib pipeline downloads (via `dlib-data/install.sh`) three models by Davis King from [dlib-models](https://github.com/davisking/dlib-models) (the ResNet face recognizer, the CNN face detector and the 5-point landmark model). The author released them into the public domain; the 68-point landmark model is intentionally **not** used because its training dataset (iBUG 300-W) excludes commercial use.

It also relies on [OpenCV](https://opencv.org) (Apache-2.0) and [dlib](https://dlib.net) (Boost). Windows Hello™ is a trademark of Microsoft — howdy is not affiliated with Microsoft.

## CLI

The installer adds a `howdy` command to manage face models for the current user. Use `howdy --help` or `man howdy` to list the available options.

Usage:
```
howdy [-U user] [-y] command [argument]
```

| Command   | Description                                   |
|-----------|-----------------------------------------------|
| `add`     | Add a new face model for a user               |
| `clear`   | Remove all face models for a user             |
| `config`  | Open the config file in your default editor   |
| `disable` | Disable or enable howdy                       |
| `list`    | List all saved face models for a user         |
| `remove`  | Remove a specific model for a user            |
| `snapshot`| Take a snapshot of your camera input          |
| `test`    | Test the camera and recognition methods       |
| `version` | Print the current version number              |

## Contributing [![](https://img.shields.io/travis/boltgolt/howdy/dev.svg?label=dev%20build)](https://github.com/boltgolt/howdy/tree/dev) [![](https://img.shields.io/github/issues-raw/boltgolt/howdy/enhancement.svg?label=feature+requests&colorB=4c1)](https://github.com/boltgolt/howdy/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement)

The easiest ways to contribute to Howdy is by starring the repository and opening GitHub issues for features you'd like to see. If you want to do more, you can also [buy me a coffee](https://www.buymeacoffee.com/boltgolt).

Code contributions are also very welcome. If you want to port Howdy to another distro, feel free to open an issue for that too.

## Troubleshooting

Any Python errors get logged directly into the console and should indicate what went wrong. If authentication still fails but no errors are printed, you could take a look at the last lines in `/var/log/auth.log` to see if anything has been reported there.

Please first check the [wiki on common issues](https://github.com/boltgolt/howdy/wiki/Common-issues) and 
if you encounter an error that hasn't been reported yet, don't be afraid to open a new issue.

## A note on security

This package is in no way as secure as a password and will never be. Although it's harder to fool than normal face recognition, a person who looks similar to you, or a well-printed photo of you could be enough to do it. Howdy is a more quick and convenient way of logging in, not a more secure one.

To minimize the chance of this program being compromised, it's recommended to leave Howdy in `/lib/security` and to keep it read-only.

DO NOT USE HOWDY AS THE SOLE AUTHENTICATION METHOD FOR YOUR SYSTEM.
