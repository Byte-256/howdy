# Save the face of the user in encoded form
# Captures multiple head poses (frontal, left, right, up and down) in a
# single enrollment so authentication works from more angles later

# Import required modules
import time
import os
import sys
import json
import configparser
import builtins
import numpy as np
import paths_factory

from recorders.video_capture import VideoCapture
from i18n import _

# Read config from disk
config = configparser.ConfigParser()
config.read(paths_factory.config_file_path())

# Read the detection method out of the config, models are only compatible
# with the method they were generated with
use_cnn = config.getboolean("core", "use_cnn", fallback=False)
use_dnn = config.getboolean("core", "use_dnn", fallback=False)
method = "sface" if use_dnn else "dlib"
# The amount of head poses to capture per enrollment
POSE_CAPTURE = config.getboolean("core", "add_poses", fallback=True)
dnn_face_recognizer = None

# Only import dlib when the DNN pipeline is not in use
if not use_dnn:
	try:
		import dlib
	except ImportError as err:
		print(err)

		print(_("\nCan't import the dlib module, check the output of"))
		print("pip3 show dlib")
		sys.exit(1)

# OpenCV needs to be imported after dlib
import cv2

if use_dnn:
	# Use OpenCV's DNN models (YuNet detector + SFace recognizer), these can
	# be hardware accelerated on the GPU
	import dnn_recognition

	try:
		dnn_face_recognizer = dnn_recognition.DnnFaceRecognizer(config)
	except FileNotFoundError:
		sys.exit(1)
else:
	# Test if at lest 1 of the data files is there and abort if it's not
	if not os.path.isfile(paths_factory.shape_predictor_5_face_landmarks_path()):
		print(_("Data files have not been downloaded, please run the following commands:"))
		print("\n\tcd " + paths_factory.dlib_data_dir_path())
		print("\tsudo ./install.sh\n")
		sys.exit(1)

	# Use the CNN detector if enabled
	if use_cnn:
		face_detector = dlib.cnn_face_detection_model_v1(paths_factory.mmod_human_face_detector_path())
	else:
		face_detector = dlib.get_frontal_face_detector()

	pose_predictor = dlib.shape_predictor(paths_factory.shape_predictor_5_face_landmarks_path())
	face_encoder = dlib.face_recognition_model_v1(paths_factory.dlib_face_recognition_resnet_model_v1_path())

user = builtins.howdy_user
# The permanent file to store the encoded model in
enc_file = paths_factory.user_model_path(user)
# Known encodings of existing models
encodings = []

# Make the ./models folder if it doesn't already exist
if not os.path.exists(paths_factory.user_models_dir_path()):
	print(_("No face model folder found, creating one"))
	os.makedirs(paths_factory.user_models_dir_path())

# To try read a premade encodings file if it exists
try:
	encodings = json.load(open(enc_file))
except FileNotFoundError:
	encodings = []

# Print a warning if too many encodings are being added
if len(encodings) > 3:
	print(_("NOTICE: Each additional model slows down the face recognition engine slightly"))
	print(_("Press Ctrl+C to cancel\n"))

# Make clear what we are doing if not human
if not builtins.howdy_args.plain:
	print(_("Adding face model for the user ") + user)

# Set the default label
label = "Initial model"

# some id's can be skipped, but the last id is always the maximum
next_id = encodings[-1]["id"] + 1 if encodings else 0

# Get the label from the cli arguments if provided
if builtins.howdy_args.arguments:
	label = builtins.howdy_args.arguments[0]

# Or set the default label
else:
	label = _("Model #") + str(next_id)

# Keep de default name if we can't ask questions
if builtins.howdy_args.y:
	print(_('Using default label "%s" because of -y flag') % (label, ))
else:
	# Ask the user for a custom label
	label_in = input(_("Enter a label for this new model [{}]: ").format(label))

	# Set the custom label (if any) and limit it to 24 characters
	if label_in != "":
		label = label_in[:24]

# Remove illegal characters
if "," in label:
	print(_("NOTICE: Removing illegal character \",\" from model name"))
	label = label.replace(",", "")

# Prepare the metadata for insertion
insert_model = {
	"time": int(time.time()),
	"label": label,
	"id": next_id,
	# The detection method of the data, models are only compatible with
	# the method they were generated with
	"type": method,
	"data": []
}

# Set up video_capture
video_capture = VideoCapture(config)

dark_threshold = config.getfloat("video", "dark_threshold", fallback=60)

clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))


def encode_face(frame, face_location):
	"""Create an encoding for a face location with the configured method"""
	if use_dnn:
		return dnn_face_recognizer.encode(frame, face_location)

	face_landmark = pose_predictor(frame, face_location)
	return np.array(face_encoder.compute_face_descriptor(frame, face_landmark, 1))


def detect_single_face(frame, gsframe):
	"""
	Detect faces in the frame and pick the only one out, returns None if
	zero or multiple faces are detected
	"""
	if use_dnn:
		face_locations = dnn_face_recognizer.detect(frame, gsframe)
	else:
		face_locations = face_detector(gsframe, 1)

	# If there's not exactly one face we can't know which one belongs to
	# the user
	if len(face_locations) != 1:
		return None

	face_location = face_locations[0]
	if not use_dnn and use_cnn:
		# Convert the mmod detector result to a plain rectangle
		face_location = face_location.rect

	# Faces smaller than this are too small for reliable landmarks
	width = face_location[2] if use_dnn else face_location.width()
	if width < 40:
		return None

	return face_location


def face_points(frame, face_location):
	"""
	Get the semantic face points, the exact order of the 5 landmark points
	differs per detector and to detangle that from the code the points are
	sorted here from top to bottom: 2 eyes, nose, 2 mouth corners
	"""
	if use_dnn:
		pts = [(face_location[4 + 2 * i], face_location[5 + 2 * i]) for i in range(5)]
	else:
		landmarks = pose_predictor(frame, face_location)
		pts = [(landmarks.part(i).x, landmarks.part(i).y) for i in range(5)]

	# Sort the points by height
	pts = sorted(pts, key=lambda p: p[1])

	# With the head upright the 2 highest points are the eyes, the 3rd is
	# the nose and the 2 lowest are the mouth corners
	eye_left, eye_right = sorted(pts[0:2], key=lambda p: p[0])
	nose, mouth_left, mouth_right = pts[2], pts[3], pts[4]
	eye_mid = ((eye_left[0] + eye_right[0]) / 2, (eye_left[1] + eye_right[1]) / 2)
	# The horizontal distance between the eyes, this normalizes the pose
	# indicators so they don't depend on how close the user is sitting
	eye_span = max(abs(eye_left[0] - eye_right[0]), 1.0)

	return eye_mid, nose, eye_span


def pose_indicator(eye_mid, nose, eye_span):
	"""
	Returns the signed yaw (how much the head is turned) and the signed
	pitch (how much the head is tilted up or down), both normalized by the
	distance between the eyes. Positive yaw means the nose points to the
	right in the image, positive pitch means the nose sits lower relative
	to the eyes (looking down)
	"""
	yaw = (nose[0] - eye_mid[0]) / eye_span
	pitch = (nose[1] - eye_mid[1]) / eye_span

	return yaw, pitch


# How many frames per pose to capture
POSES = ["left", "right", "up", "down"]
# Text shown to the user per head pose
POSE_PROMPTS = {
	"left": _("Turn your head to the left"),
	"right": _("Turn your head to the right"),
	"up": _("Tilt your head up, look at the ceiling"),
	"down": _("Tilt your head down, look at the floor"),
}
FRAMES_PER_POSE = 3
# In what range, relative to the distance between the eyes, the face has
# to be turned before it counts as looking that direction
MIN_TURN = 0.35
MIN_TILT = 0.20
# How far apart in time captured frames of the same pose have to be
FRAME_GAP = 0.35
# How many seconds a pose detection gets before it's skipped
POSE_TIMEOUT = 10


def capture_pose(direction, frames_wanted, gate, deadline):
	"""
	Wait for the user to look in the given direction and capture the given
	amount of encoding frames. The gate function decides if the current
	frame matches the requested pose
	"""
	print(_("\n" + POSE_PROMPTS[direction]))

	pose_encodings = []
	last_capture = 0

	while time.time() < deadline and len(pose_encodings) < frames_wanted:
		frame, gsframe = read_valid_frame()
		if frame is None:
			continue

		face_location = detect_single_face(frame, gsframe)
		if face_location is None:
			continue

		if not gate(frame, face_location):
			continue

		# Don't capture multiple frames of the exact same pose directly
		# after each other
		if time.time() - last_capture < FRAME_GAP:
			continue

		pose_encodings.append(encode_face(frame, face_location))
		last_capture = time.time()
		print(_("\tCaptured {num}/{total}").format(num=len(pose_encodings), total=frames_wanted))

	return pose_encodings


def read_valid_frame():
	"""
	Read a frame from the camera and return (frame, equalized grayscale)
	or (None, None) if the frame blacks out or is too dark
	"""
	frame, gsframe = video_capture.read_frame()
	gsframe = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
	gsframe = clahe.apply(gsframe)

	# Create a histogram of the image with 8 values
	hist = cv2.calcHist([gsframe], [0], None, [8], [0, 256])
	# All values combined for percentage calculation
	hist_total = np.sum(hist)

	# Calculate frame darkness
	darkness = (hist[0] / hist_total * 100)

	# If the image is fully black due to a bad camera read, or too dark to
	# be usable, let the caller know this frame is not valid
	if (hist_total == 0) or (darkness == 100) or (darkness > dark_threshold):
		return None, None

	return frame, gsframe


print(_("\nPlease look straight into the camera"))

# Give the user time to read
time.sleep(2)

# The encodings of the straight face, used as the baseline pose
frontal = []
# The signed yaw and pitch of the straight face, captures are compared
# against this to detect how much a face moved
base_yaw, base_pitch = 0.0, 0.0
# Count the number of read frames
frames = 0
# How many good frames we want of the straight face
WANTED_FRONTAL = 3
# Give the frontal scan a budget of 120 frames (about 4 seconds at 30fps)
DEADLINE_FRAMES = 120

# Loop through frames till we have enough captures or hit the frame limit
while frames < DEADLINE_FRAMES and len(frontal) < WANTED_FRONTAL:
	frames += 1

	# Grab a single frame of video
	frame, gsframe = read_valid_frame()
	if frame is None:
		continue

	face_location = detect_single_face(frame, gsframe)
	if face_location is None:
		continue

	# Don't capture frames of the exact same pose directly after each other
	if frontal and time.time() - frontal[-1][0] < FRAME_GAP:
		continue

	# Get the pose of the face to save as baseline
	eye_mid, nose, eye_span = face_points(frame, face_location)
	yaw, pitch = pose_indicator(eye_mid, nose, eye_span)

	print(_("\tCaptured {num}/{total}").format(num=len(frontal) + 1, total=WANTED_FRONTAL))
	frontal.append((time.time(), encode_face(frame, face_location), yaw, pitch))

# If we've found no faces (or only unusable ones), try to determine why
if not frontal:
	# Check if the camera delivered any frames at all
	tested = 0
	for _ in range(5):
		tested += 1 if read_valid_frame()[0] is not None else 0

	if tested == 0:
		print(_("Camera saw only black frames - is IR emitter working?"))
	elif len(frontal) == 0 and frames >= DEADLINE_FRAMES:
		print(_("No face detected, aborting"))
	video_capture.release()
	sys.exit(1)

# Save the frontal encodings and use the average pose as the baseline
insert_model["data"] += [entry[1].tolist() for entry in frontal]
base_yaw = np.mean([entry[2] for entry in frontal])
base_pitch = np.mean([entry[3] for entry in frontal])

# The frontal encodings, used to check that new captures are different
frontal_encodings = np.array([entry[1] for entry in frontal])

# Now capture the additional head poses, gate on the pose relative to the
# captured frontal pose so each pose really gets a different angle
if POSE_CAPTURE:
	for direction in POSES:
		def per_pose_gate(frame, face_location, direction=direction):
			eye_mid, nose, eye_span = face_points(frame, face_location)
			yaw, pitch = pose_indicator(eye_mid, nose, eye_span)

			# The heading relative to the captured frontal pose, negative
			# for left in the image and positive for right
			heading = yaw - base_yaw
			tilt = pitch - base_pitch

			if direction == "left":
				return heading < -MIN_TURN
			if direction == "right":
				return heading > MIN_TURN
			if direction == "up":
				return tilt < -MIN_TILT
			if direction == "down":
				return tilt > MIN_TILT

		pose_encodings = capture_pose(direction, FRAMES_PER_POSE, per_pose_gate, time.time() + POSE_TIMEOUT)

		if not pose_encodings:
			print(_("NOTICE: Could not capture the {direction} pose, continuing without it").format(direction=_(direction.title())))

		insert_model["data"] += [encoding.tolist() for encoding in pose_encodings]

video_capture.release()

# Insert full object into the list
encodings.append(insert_model)

# Save the new encodings to disk
with open(enc_file, "w") as datafile:
	json.dump(encodings, datafile)

# Give let the user know how it went
print(_("""\nScan complete
Added {num} encodings to {user}'s model""").format(num=len(insert_model["data"]), user=user))
