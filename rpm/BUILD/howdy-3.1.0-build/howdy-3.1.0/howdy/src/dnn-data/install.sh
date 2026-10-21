#!/bin/bash

echo "Downloading 2 required data files..."

# Check if wget is installed
if hash wget;then
	# Check if wget supports the option to only show the progress bar
	wget --help | grep -q "\--show-progress" && \
		_PROGRESS_OPT="-q --show-progress" || _PROGRESS_OPT=""

	# Download the models
	wget $_PROGRESS_OPT --tries 5 https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
	wget $_PROGRESS_OPT --tries 5 https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx

# Otherwise fall back on curl
else
	curl --location --retry 5 --output face_detection_yunet_2023mar.onnx https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
	curl --location --retry 5 --output face_recognition_sface_2021dec.onnx https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
fi

echo " "
echo "Unpacking..."
bzip2 -d -f *.bz2
