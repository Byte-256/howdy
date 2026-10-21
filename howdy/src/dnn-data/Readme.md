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

## Model credits and licenses

Both models come from [OpenCV Zoo](https://github.com/opencv/opencv_zoo)
(model hosting has since moved to OpenCV's Hugging Face page,
<https://huggingface.co/opencv>). They are redistributed here / shipped in
the release packages as permitted by their licenses:

- **YuNet** face detector - MIT License, Copyright (c) 2020 Shiqi Yu
  ([model license](https://github.com/opencv/opencv_zoo/blob/main/models/face_detection_yunet/LICENSE))
- **SFace** face recognizer - Apache License 2.0, OpenCV / OpenCV Zoo
  ([model license](https://github.com/opencv/opencv_zoo/blob/main/models/face_recognition_sface/LICENSE))

Thanks to the respective authors and to the OpenCV maintainers for the
OpenCV Zoo collection.
