# Hardware accelerated face detection and identification using OpenCV's DNN
# module (YuNet detector + SFace recognizer) instead of dlib.
#
# The models used here are tiny (compared to the dlib data files) and can run
# on any OpenCL capable GPU (AMD, Intel, NVIDIA), on CUDA capable NVIDIA GPUs
# or on the CPU, depending on the "dnn_backend" and "dnn_target" config values.
#
# The corresponding .onnx model files need to be present in the dnn data
# folder, they can be downloaded with the install.sh script in there:
#
# 	cd <dnn_data_dir>
# 	sudo ./install.sh

# Import required modules
import os

# Some OpenCL drivers (like Mesa's Rusticl for AMD GPUs) need environment
# configuration before OpenCL gets initialized, and OpenCV's DNN module
# only allows GPU typed devices unless told otherwise. Set these as early
# as possible, before OpenCV is imported
os.environ.setdefault("OPENCV_DNN_OPENCL_ALLOW_ALL_DEVICES", "1")
os.environ.setdefault("RUSTICL_ENABLE", "radeonsi")

import cv2
import numpy as np

import paths_factory
from i18n import _


# Maps the "dnn_backend" config value to an OpenCV DNN backend id
DNN_BACKENDS = {
	"cpu": cv2.dnn.DNN_BACKEND_OPENCV,
	"opencl": cv2.dnn.DNN_BACKEND_OPENCV,
	"vulkan": cv2.dnn.DNN_BACKEND_VKCOM,
	"cuda": cv2.dnn.DNN_BACKEND_CUDA,
}

# Maps the "dnn_target" config value to an OpenCV DNN target id
DNN_TARGETS = {
	"cpu": cv2.dnn.DNN_TARGET_CPU,
	"cpu_fp16": cv2.dnn.DNN_TARGET_CPU_FP16,
	"opencl": cv2.dnn.DNN_TARGET_OPENCL,
	"opencl_fp16": cv2.dnn.DNN_TARGET_OPENCL_FP16,
	"vulkan": cv2.dnn.DNN_TARGET_VULKAN,
	"cuda": cv2.dnn.DNN_TARGET_CUDA,
	"cuda_fp16": cv2.dnn.DNN_TARGET_CUDA_FP16,
}

# Default targets per backend if "dnn_target" is set to auto
DEFAULT_TARGETS = {
	"cpu": "cpu",
	"opencl": "opencl",
	"vulkan": "vulkan",
	"cuda": "cuda_fp16",
}


class DnnFaceRecognizer:
	"""
	Creates an accelerated face recognizer pair consisting of the YuNet face
	detector and the SFace face recognizer.

	Both networks get initialized on the backend and target configured in the
	"core" section of the howdy config (dnn_backend, dnn_target). If the
	requested hardware backend does not work, the networks fall back on the
	CPU with a warning.
	"""

	def __init__(self, config, backend=None, target=None, fallback=True):
		# Read the backend and target out of the config if not given
		if backend is None:
			backend = config.get("core", "dnn_backend", fallback="cpu").lower()
		if target is None:
			target = config.get("core", "dnn_target", fallback="auto").lower()

		# Abort if the model files have not been downloaded yet
		for path in [paths_factory.yunet_onnx_path(), paths_factory.sface_onnx_path()]:
			if not os.path.isfile(path):
				print(_("DNN data files have not been downloaded, please run the following commands:"))
				print("\n\tcd " + paths_factory.dnn_data_dir_path())
				print("\tsudo ./install.sh\n")

				# __init__ isn't the place to sys.exit, raise instead
				raise FileNotFoundError(path)

		# Try to load the networks on the requested backend, fall back on
		# the CPU if that fails
		tries = [(backend, target)]
		if fallback and backend != "cpu":
			tries += [("cpu", "auto")]

		for index, (try_backend, try_target) in enumerate(tries):
			try:
				self._load(config, try_backend, try_target)
				return
			except Exception as err:
				# Re-raise the error if there is no fallback left
				if index >= len(tries) - 1:
					raise

				print(_("WARNING: Could not start the DNN pipeline on the {backend} backend, falling back to cpu").format(backend=try_backend))
				print(str(err) + "\n")

	def _load(self, config, backend, target):
		"""Create the detector and recognizer networks on the given backend"""
		# Resolve the automatic target for this backend
		if target in ["", "auto"]:
			target = DEFAULT_TARGETS[backend]

		self.backend_name = backend
		self.target_name = target

		backend_id = DNN_BACKENDS[backend]
		target_id = DNN_TARGETS[target]

		# Load YuNet as the face detector, input size is set before every
		# detect call as it can change when frames get rotated
		self.detector = cv2.FaceDetectorYN.create(
			paths_factory.yunet_onnx_path(),
			"",
			(320, 240),
			score_threshold=0.6,
			nms_threshold=0.3,
			top_k=200,
			backend_id=backend_id,
			target_id=target_id,
		)
		self._input_size = (320, 240)

		# Load SFace as the face recognizer
		self.recognizer = cv2.FaceRecognizerSF.create(
			paths_factory.sface_onnx_path(),
			"",
			backend_id,
			target_id,
		)

		# Run a warmup forward pass on both networks, some backends only
		# fail on their first real inference and not already on init
		dummy = np.zeros((64, 64, 3), dtype=np.uint8)
		self.detector.setInputSize((64, 64))
		self._input_size = (64, 64)
		self.detector.detect(dummy)
		dummy_face = np.array([[8, 8, 48, 48] + list(range(8, 18)) + [1]], dtype=np.float32).reshape(1, 15)
		self.recognizer.feature(self.recognizer.alignCrop(dummy, dummy_face))

	def detect(self, frame, gsframe=None):
		"""
		Detect all faces in the frame.

		The grayscale version of the frame gets used for detection if it is
		provided (it already had CLAHE applied to it), the returned faces are
		maps into the (color) frame given in frame.

		Returns an array where each row is:
		 [x, y, w, h, 5 landmark points (10 values), score]
		"""
		# Convert the grayscale detection frame to the 3 channel format
		# YuNet expects
		if gsframe is not None and gsframe.ndim == 2:
			detect_frame = cv2.cvtColor(gsframe, cv2.COLOR_GRAY2BGR)
			width, height = gsframe.shape[1], gsframe.shape[0]
		else:
			detect_frame = frame
			width, height = frame.shape[1], frame.shape[0]

		# Only call setInputSize if the frame size changed
		if (width, height) != self._input_size:
			self.detector.setInputSize((width, height))
			self._input_size = (width, height)

		# The first item of the return tuple is the input image, the second
		# one the Nx15 array with detected faces or None if none found
		faces = self.detector.detect(detect_frame)[1]

		# YuNet returns None instead of an empty array when no faces are
		# found, make that iterable
		if faces is None:
			return []

		return faces

	def encode(self, frame, face):
		"""
		Create a 128 dimension face encoding for the face given as one row of
		the format returned by detect(), aligned and cropped out of frame
		"""
		aligned_face = self.recognizer.alignCrop(frame, face)
		feature = np.array(self.recognizer.feature(aligned_face))[0]

		# The SFace feature output is not unit normalized in all OpenCV
		# builds, normalize it so the cosine distance can be computed
		# downstream with a plain dot product
		return feature / max(np.linalg.norm(feature), 1e-6)
