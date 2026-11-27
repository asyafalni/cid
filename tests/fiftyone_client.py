"""cid's exports, loaded by the real FiftyOne (docs/roadmap.md, E5).

Run by tests/fiftyone_client.sh with three folders, each a `cid clone
--format` of the same release: yolo, coco, voc. Every call here is what a
person types into FiftyOne; each check prints one line, and any failure
stops it. The release holds two frames, one in train and one in val, each
with one "person" box.
"""
import sys

import fiftyone as fo

yolo, coco, voc = sys.argv[1:4]


def ok(what):
    print(f"ok  {what}")


def boxes(dataset, field):
    return [d for s in dataset if s[field] is not None for d in s[field].detections]


# yolo: no argument but the split. FiftyOne finds a label by swapping the
# image path's /images/ for /labels/, which is why cid keeps images there.
for split in ("train", "val"):
    ds = fo.Dataset.from_dir(dataset_dir=yolo, dataset_type=fo.types.YOLOv5Dataset, split=split)
    found = boxes(ds, "ground_truth")
    assert len(ds) == 1 and len(found) == 1 and found[0].label == "person", (split, len(ds), found)
    # x, y, w, h as shares of a 4 x 3 image: the box {x:1, y:1, w:2, h:1}.
    assert [round(v, 4) for v in found[0].bounding_box] == [0.25, 0.3333, 0.5, 0.3333], found[0].bounding_box
ok("yolo: a split at a time, the box where cid has it")

# coco: one instances file per split, the images where the folder has them.
for split in ("train", "val"):
    ds = fo.Dataset.from_dir(
        dataset_type=fo.types.COCODetectionDataset,
        data_path=coco,
        labels_path=f"{coco}/annotations/instances_{split}.json",
    )
    field = "detections" if "detections" in ds.get_field_schema() else "ground_truth"
    found = boxes(ds, field)
    assert len(ds) == 1 and len(found) == 1 and found[0].label == "person", (split, len(ds), found)
ok("coco: data_path and a split's labels_path")

# voc: the folder and its Annotations.
ds = fo.Dataset.from_dir(dataset_type=fo.types.VOCDetectionDataset, data_path=voc, labels_path=f"{voc}/Annotations")
found = boxes(ds, "ground_truth")
assert len(ds) == 2 and len(found) == 2 and {d.label for d in found} == {"person"}, (len(ds), found)
ok("voc: data_path and labels_path, both frames")
