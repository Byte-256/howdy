# DNN data files

These files are for the hardware-accelerated face detection and identification
path (`use_dnn = true` in the `[core]` section of config.ini). They use
OpenCV's DNN module and can, depending on your hardware and the configured
`dnn_backend` / `dnn_target` values, run on the GPU instead of the CPU.

The models are tiny compared to the dlib data files and come from the
official OpenCV Zoo:

- `face_detection_yunet_2023mar.onnx` (YuNet, ~260 KB) - face detector,
  <https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet>
- `face_recognition_sface_2021dec.onnx` (SFace, ~37 MB) - face recognizer,
  <https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface>

Run `./install.sh` in this directory as root to download them.
