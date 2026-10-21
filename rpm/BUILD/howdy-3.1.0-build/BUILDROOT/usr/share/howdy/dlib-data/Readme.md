Download and unpack `dlib` data files from https://github.com/davisking/dlib-models repository:

```
shell
wget https://github.com/davisking/dlib-models/raw/master/dlib_face_recognition_resnet_model_v1.dat.bz2
wget https://github.com/davisking/dlib-models/raw/master/mmod_human_face_detector.dat.bz2
wget https://github.com/davisking/dlib-models/raw/master/shape_predictor_5_face_landmarks.dat.bz2
bunzip *bz2
```

## Model credits and licensing

All three files are trained models by Davis King ([dlib-models](https://github.com/davisking/dlib-models)),
released by the author into the **public domain** ("anyone can do whatever
they want with these model files"). Notes from the author worth knowing:

- `dlib_face_recognition_resnet_model_v1.dat` was trained on a dataset
  derived from research face collections (FaceScrub, VGG-Face) plus web
  images.
- `mmod_human_face_detector.dat` and `shape_predictor_5_face_landmarks.dat`
  were annotated by the author on public datasets from the internet.

Note: the `shape_predictor_68_face_landmarks` models from the same
repository are NOT used by howdy, because their training data (the iBUG
300-W dataset) excludes commercial use. The 5-point model has no such
restriction.
