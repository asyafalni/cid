#!/bin/sh
# Fills a fresh one-machine cid (this folder's docker-compose.yml, already
# up) with three demo datasets, so every page of the dashboard has
# something to show:
#
#   demo/datasets/street-scenes   annotated: 50 street photos with their boxes,
#                                 three splits, two releases (a detector's
#                                 mistakes, then the review that fixes them)
#   demo/datasets/city-sounds     files: recordings, clips, a PDF, tables;
#                                 two releases (rows added and changed)
#   demo/models/street-detector   a model, trained on street-scenes v1.1
#
# The photos are real: fifty pictures of Open Images, CC BY 2.0, fetched
# from its bucket and checked against the hashes in demo/street-scenes.tsv,
# with the boxes its annotators drew (demo/CREDITS.md names every author).
# The clips are a slow pan across two of those photos and the sounds are
# shaped noise, both made by the ffmpeg inside the server's image.
# So this needs docker, the cid command, and the network for the photos.
# Annotations go in as the annotation platform writes them: revision rows
# in the database, then a commit and a release through the API.
#
#   docker compose -f deploy/compose/docker-compose.yml up --build -d
#   sh deploy/compose/demo.sh
#   open http://127.0.0.1:7070 and sign in with the token cid-local-token
#
# Run it once on a fresh stack; a second run says the datasets exist.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COMPOSE="${COMPOSE:-docker compose -f $HERE/docker-compose.yml}"
export CID_SERVER="${CID_SERVER:-http://127.0.0.1:${CID_PORT:-7070}}"
export CID_TOKEN="${CID_TOKEN:-cid-local-token}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
say() { printf '%s\n' "$*"; }
die() { say "demo: $*" >&2; exit 1; }

curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 ||
    die "no cid answers at $CID_SERVER. Start it: docker compose -f deploy/compose/docker-compose.yml up --build -d"
if command -v cid >/dev/null 2>&1; then CID=cid; else
    # The image's own, as deploy/compose/README.md takes it out (Linux).
    $COMPOSE cp cid:/opt/cid/bin "$WORK/cid-bin" >/dev/null && CID="$WORK/cid-bin/cid" ||
        die "no cid command here. Put it on the PATH (deploy/compose/README.md, step 2), then run this again."
fi
api() { # method, path, json body
    curl -sf -X "$1" -H "Authorization: Bearer $CID_TOKEN" -H 'content-type: application/json' \
        "$CID_SERVER/v0/datasets$2" ${3:+--data "$3"}
}
sql() { $COMPOSE exec -T timescaledb psql -q -U cid -d cid -v ON_ERROR_STOP=1 >/dev/null; }
in_server() { $COMPOSE exec -T cid sh -c "$1"; }
repo() { in_server "test -d /git/$1.git || git init -q --bare -b main /git/$1.git"; }
api GET /demo/datasets/street-scenes/-/info >/dev/null 2>&1 && die "the demo datasets are already here. Look at $CID_SERVER"

# --- the photos, from Open Images ---------------------------------------------
say "Fetching 50 street photos (Open Images, CC BY 2.0)…"
PHOTOS="$HERE/demo/street-scenes.tsv"
BUCKET="${CID_DEMO_PHOTOS:-https://open-images-dataset.s3.amazonaws.com/validation}"
mkdir -p "$WORK/frames"
grep '^F' "$PHOTOS" | while IFS="$(printf '\t')" read -r _ n id hash _; do
    f="$WORK/frames/$n.jpg"
    curl -sfL -o "$f" "$BUCKET/$id.jpg" ||
        die "could not fetch photo $id from $BUCKET. Check the network, then run this again."
    [ "$("$CID" hash-object "$f")" = "$hash" ] || die "photo $id is not the one recorded (its hash differs); nothing was imported."
done

# --- sounds and clips, made inside the server's image ------------------------
# The clips are a slow pan across two of the photos (0 and 37, credited with
# the rest); the sounds are shaped noise, loud and quiet as a street is, and
# one calibration tone.
say "Making the sounds and clips (ffmpeg, in the server's image)…"
in_server 'rm -rf /tmp/demo && mkdir -p /tmp/demo/audio /tmp/demo/video'
$COMPOSE cp "$WORK/frames/0.jpg" cid:/tmp/demo/a.jpg >/dev/null 2>&1
$COMPOSE cp "$WORK/frames/37.jpg" cid:/tmp/demo/b.jpg >/dev/null 2>&1
in_server '
set -e
cd /tmp/demo
ff="ffmpeg -nostdin -loglevel error -y"
$ff -f lavfi -i "anoisesrc=color=pink:duration=6:seed=11,volume=volume=0.25+0.75*abs(sin(2*PI*t/2.3)):eval=frame,lowpass=f=3200" audio/main-st.wav
$ff -f lavfi -i "anoisesrc=color=brown:duration=6:seed=12,volume=volume=0.5+0.5*sin(2*PI*t/5):eval=frame,lowpass=f=900" audio/harbour-rd.wav
$ff -f lavfi -i "anoisesrc=color=pink:duration=5:seed=13,volume=volume=0.15+0.85*pow(sin(PI*t/5)\,4):eval=frame" -f lavfi -i "sine=frequency=120:duration=5" \
  -filter_complex "[1:a]volume=0.25[h];[0:a][h]amix=inputs=2:normalize=0" audio/station-sq.flac
$ff -f lavfi -i "anoisesrc=color=white:duration=5:seed=14,volume=volume=0.08+0.12*abs(sin(2*PI*t/1.1)):eval=frame,highpass=f=1500" audio/park-ln.mp3
$ff -f lavfi -i "anoisesrc=color=pink:duration=6:seed=15,volume=volume=0.3+0.7*abs(sin(2*PI*t/3.7)):eval=frame,lowpass=f=2400" audio/bridge-st.wav
$ff -f lavfi -i "sine=frequency=1000:duration=2" audio/calibration-1khz.wav
pan() { # photo, clip: six seconds across the picture, with the street under it
  $ff -i "$1" -f lavfi -i "anoisesrc=color=brown:amplitude=0.25:duration=6:seed=21" \
    -vf "scale=1600:-2,zoompan=z=1.3:x=(iw-iw/zoom)*on/150:y=(ih-ih/zoom)/2:d=150:s=640x360:fps=25" \
    -frames:v 150 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$2"
}
pan a.jpg video/trolley-crossing.mp4
pan b.jpg video/bus-stop.mp4
rm a.jpg b.jpg
'
$COMPOSE cp cid:/tmp/demo/. "$WORK/media" >/dev/null 2>&1

# A one-page PDF, written by hand: its title, then a line a row.
pdf() { # file, title, lines…
    out=$1; title=$2; shift 2
    text="BT /F1 20 Tf 72 760 Td ($title) Tj ET"; y=722
    for line; do text="$text BT /F2 11 Tf 72 $y Td ($line) Tj ET"; y=$((y - 19)); done
    : > "$out"; offsets=""
    obj() { offsets="$offsets $(wc -c < "$out" | tr -d ' ')"; printf '%s\n' "$1" >> "$out"; }
    printf '%%PDF-1.4\n' >> "$out"
    obj '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj'
    obj '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj'
    obj '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >> endobj'
    obj "4 0 obj << /Length ${#text} >> stream
$text
endstream endobj"
    obj '5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >> endobj'
    obj '6 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Courier >> endobj'
    xref=$(wc -c < "$out" | tr -d ' ')
    { printf 'xref\n0 7\n0000000000 65535 f \n'
      for o in $offsets; do printf '%010d 00000 n \n' "$o"; done
      printf 'trailer << /Size 7 /Root 1 0 R >>\nstartxref\n%s\n%%%%EOF\n' "$xref"; } >> "$out"
}

# --- street-scenes: annotated, the platform's way ----------------------------
say "street-scenes: the photos with their boxes, then a second release…"
repo street-scenes
api POST "" '{"name":"demo/datasets/street-scenes","kind":"annotated","git_url":"/git/street-scenes.git"}' >/dev/null ||
    die "could not create demo/datasets/street-scenes"
DS_ID=$($COMPOSE exec -T timescaledb psql -tA -U cid -d cid -c "SELECT dataset_id FROM datasets WHERE name = 'demo/datasets/street-scenes'")
api POST /demo/datasets/street-scenes/-/policy '{"version":"p1","body":{"rule":"box every vehicle, bicycle, person, traffic light and sign; occluded when part of it is hidden"}}' >/dev/null

# Upload as the platform does: ask what is missing, PUT it, register it.
upload() { # first, last frame number
    rows=$(awk -F'\t' -v a="$1" -v b="$2" '$1 == "F" && $2 >= a && $2 <= b' "$PHOTOS")
    hashes=$(printf '%s\n' "$rows" | awk -F'\t' '{printf "%s\"%s\"", (NR > 1 ? "," : ""), $4}')
    items=$(printf '%s\n' "$rows" | awk -F'\t' '{printf "%s{\"hash\":\"%s\",\"size\":%s,\"media_type\":\"image/jpeg\",\"width\":%s,\"height\":%s}", (NR > 1 ? "," : ""), $4, $5, $6, $7}')
    api POST /demo/datasets/street-scenes/-/check-hashes "{\"hashes\":[$hashes]}" |
        tr '{' '\n' | sed -n 's/.*"hash":"\([0-9a-f]*\)".*"url":"\([^"]*\)".*/\1 \2/p' |
        while read -r h url || [ -n "$h" ]; do   # the last line ends without a newline
            n=$(awk -F'\t' -v h="$h" '$1 == "F" && $4 == h { print $2; exit }' "$PHOTOS")
            curl -sf -X PUT --data-binary "@$WORK/frames/$n.jpg" "$url" >/dev/null
        done
    api POST /demo/datasets/street-scenes/-/register-items "{\"items\":[$items]}" >/dev/null
}
# The revisions of frames a to b, as SQL: each photo's path and split, then
# its boxes. Every fourth frame was boxed by a reviewer, the rest by a
# detector, which in every sixth of the first forty got it a little wrong:
# its boxes sit 40 pixels left, and it calls a car a truck. v1.1 is the
# review that puts them right (the true boxes are the manifest's).
frames_sql() {
    awk -F'\t' -v a="$1" -v b="$2" -v ds="$DS_ID" '
    $1 == "F" && $2 >= a && $2 <= b {
        split_ = ($2 % 10 == 7) ? "val" : ($2 % 10 == 9) ? "test" : "train"
        printf "INSERT INTO demo_items (n, item_id) VALUES (%d, cid_rev());\n", $2
        printf "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author) SELECT \047%s\047,\047main\047,\047frames/frame-%03d.jpg\047,\047add\047, item_id, decode(\047%s\047,\047hex\047),\047%s\047,\047agent:annotator\047 FROM demo_items WHERE n=%d;\n", ds, $2, $4, split_, $2
        printf "INSERT INTO dataset_items (item_id, dataset_id) SELECT item_id, \047%s\047 FROM demo_items WHERE n=%d;\n", ds, $2
    }
    $1 == "B" && $2 >= a && $2 <= b {
        wrong = ($2 % 6 == 1 && $2 < 40)
        cls = (wrong && $4 == "car") ? "truck" : $4
        x = wrong ? ($5 > 40 ? $5 - 40 : 0) : $5
        who = ($2 % 4 == 0) ? "user:reviewer" : "agent:detector-v2"
        attrs = ($9 == 1) ? "\047{\"occluded\":true}\047::jsonb" : "null"
        printf "INSERT INTO demo_boxes (n, k, annotation_id) VALUES (%d, %d, cid_rev());\n", $2, $3
        printf "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, attrs, author, policy_ver) SELECT \047%s\047,\047main\047, b.annotation_id, i.item_id, \047create\047,\047box\047,\047%s\047,\047{\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}\047::jsonb, %s, \047%s\047,\047p1\047 FROM demo_boxes b JOIN demo_items i USING (n) WHERE b.n=%d AND b.k=%d;\n", ds, cls, x, $6, $7, $8, attrs, who, $2, $3
    }' "$PHOTOS"
}
# The review: every box the detector got wrong, as the annotators drew it.
review_sql() {
    awk -F'\t' -v ds="$DS_ID" '
    $1 == "B" && $2 % 6 == 1 && $2 < 40 {
        attrs = ($9 == 1) ? "\047{\"occluded\":true}\047::jsonb" : "null"
        printf "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, attrs, author, policy_ver) SELECT \047%s\047,\047main\047, b.annotation_id, i.item_id, \047update\047,\047box\047,\047%s\047,\047{\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}\047::jsonb, %s, \047user:reviewer\047,\047p1\047 FROM demo_boxes b JOIN demo_items i USING (n) WHERE b.n=%d AND b.k=%d;\n", ds, $4, $5, $6, $7, $8, attrs, $2, $3
    }' "$PHOTOS"
}
lock="SELECT pg_advisory_xact_lock_shared(hashtextextended('$DS_ID' || '/main', 0));"

upload 0 39
{
    echo "CREATE TABLE demo_items (n int PRIMARY KEY, item_id uuid); CREATE TABLE demo_boxes (n int, k int, annotation_id uuid, PRIMARY KEY (n, k));"
    echo "BEGIN; $lock"
    frames_sql 0 39
    # Two traffic signs the detector saw where there are none.
    for n in 2 3; do
        echo "INSERT INTO demo_boxes (n, k, annotation_id) VALUES ($n, 99, cid_rev());"
        echo "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) SELECT '$DS_ID','main', b.annotation_id, i.item_id, 'create','box','traffic sign','{\"x\":60,\"y\":50,\"w\":70,\"h\":70}'::jsonb, 'agent:detector-v2','p1' FROM demo_boxes b JOIN demo_items i USING (n) WHERE b.n=$n AND b.k=99;"
    done
    echo "COMMIT;"
} | sql
api POST /demo/datasets/street-scenes/-/commit '{"message":"First 40 photos, boxed by the detector and a reviewer","author":"agent:annotator"}' >/dev/null
api POST /demo/datasets/street-scenes/-/tag '{"name":"v1.0","notes":"The first 40 street photos.\nBoxes by detector-v2; every fourth photo was boxed by a reviewer."}' >/dev/null

# v1.1: ten more photos, the review of the first forty, one photo to val.
upload 40 49
{
    echo "BEGIN; $lock"
    frames_sql 40 49
    review_sql
    for n in 2 3; do
        echo "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, author, policy_ver) SELECT '$DS_ID','main', b.annotation_id, i.item_id, 'delete','user:reviewer','p1' FROM demo_boxes b JOIN demo_items i USING (n) WHERE b.n=$n AND b.k=99;"
    done
    hash4=$(awk -F'\t' '$1 == "F" && $2 == 4 { print $4 }' "$PHOTOS")
    echo "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author) SELECT '$DS_ID','main','frames/frame-004.jpg','add', item_id, decode('$hash4','hex'),'val','user:reviewer' FROM demo_items WHERE n=4;"
    echo "COMMIT;"
    echo "DROP TABLE demo_items, demo_boxes;"
} | sql
api POST /demo/datasets/street-scenes/-/commit '{"message":"Ten more photos; review pass on the first forty","author":"agent:annotator"}' >/dev/null
api POST /demo/datasets/street-scenes/-/tag '{"name":"v1.1","notes":"Ten more photos.\nReview pass on the first forty: in seven photos the detector had its boxes 40 px left of their objects and called cars trucks; two traffic signs were not there; photo 4 moved to val."}' >/dev/null

# --- city-sounds: files, as a person pushes them -----------------------------
say "city-sounds: recordings, two clips, a survey sheet and tables; two releases…"
repo city-sounds
mkdir -p "$WORK/city-sounds/tables" "$WORK/city-sounds/docs" && cd "$WORK/city-sounds"
cp -r "$WORK/media/audio" "$WORK/media/video" .
mv audio/bridge-st.wav "$WORK/bridge-st.wav"            # the fifth site, in v1.1
pdf docs/survey-sheet.pdf "City sounds: noise survey, March 2026" \
    "Site          Recorded      Level   Notes" \
    "Main St       2026-03-01    71 dB   two lanes, a bus every ten minutes" \
    "Harbour Rd    2026-03-01    64 dB   ferries; quiet between them" \
    "Station Sq    2026-03-02    77 dB   the hum is the escalator" \
    "Park Ln       2026-03-02    52 dB   birds, a path, no traffic" \
    "" \
    "One handheld recorder at 1.5 m, five minutes a site, between 9 and 11." \
    "Levels are A-weighted averages. The 1 kHz tone was played before each take."
cp "$ROOT/tests/fixtures/people.parquet" tables/surveyors.parquet
cp "$ROOT/tests/fixtures/events.jsonl" tables/events.jsonl
printf 'id,street,noise_db,recorded\n1,Main St,71,2026-03-01\n2,Harbour Rd,64,2026-03-01\n3,Station Sq,77,2026-03-02\n4,Park Ln,52,2026-03-02\n' > tables/sites.csv
printf 'tables/sites.csv  id\n' > .cidkeys
printf 'Field notes, March.\nRecorded at four sites with one handheld recorder.\nThe hum at Station Sq is the escalator.\n' > NOTES.txt
"$CID" init cid@127.0.0.1:demo/datasets/city-sounds --git /git/city-sounds.git >/dev/null
"$CID" add . >/dev/null && "$CID" commit -m "March recordings, four sites" >/dev/null && "$CID" push >/dev/null
"$CID" tag v1.0 -m "March: four sites, a calibration tone, two clips of the crossings." >/dev/null
printf '5,Bridge St,69,2026-03-09\n' >> tables/sites.csv
sed -i.bak 's/^3,Station Sq,77/3,Station Sq,79/' tables/sites.csv && rm tables/sites.csv.bak
rm audio/calibration-1khz.wav
mv "$WORK/bridge-st.wav" audio/bridge-st.wav
"$CID" add . >/dev/null && "$CID" commit -m "A fifth site; Station Sq re-measured" >/dev/null && "$CID" push >/dev/null
"$CID" tag v1.1 -m "A fifth site (Bridge St). Station Sq re-measured with the new meter; the old calibration tone is gone." >/dev/null

# --- street-detector: a model, and what it was trained on --------------------
say "street-detector: a model trained on street-scenes v1.1…"
repo street-detector
mkdir -p "$WORK/street-detector" && cd "$WORK/street-detector"
head -c 4000000 /dev/urandom > weights.bin
printf '{\n  "architecture": "tiny-detector",\n  "input": [320, 240],\n  "classes": ["bicycle", "bus", "car", "motorcycle", "person", "traffic light", "traffic sign", "truck"]\n}\n' > config.json
printf 'bicycle\nbus\ncar\nmotorcycle\nperson\ntraffic light\ntraffic sign\ntruck\n' > labels.txt
"$CID" init cid@127.0.0.1:demo/models/street-detector --git /git/street-detector.git --model >/dev/null
"$CID" add . >/dev/null && "$CID" commit -m "First training run" >/dev/null && "$CID" push >/dev/null
"$CID" tag v1.0.0 --trained-on demo/datasets/street-scenes@v1.1 -m "Trained 40 epochs on street-scenes v1.1." >/dev/null

# --- previews: what the background loop would do within ten minutes ----------
say "Drawing thumbnails, waveforms and video previews…"
i=0
while [ "$i" -lt 12 ]; do
    left=$($COMPOSE exec -T timescaledb psql -tA -U cid -d cid -c "SELECT count(*) FROM previews WHERE status = 'pending'")
    [ "$left" = 0 ] && break
    in_server 'cid admin previews' >/dev/null 2>&1 || true
    i=$((i+1))
done

say ""
say "Done. Open $CID_SERVER and sign in with the token $CID_TOKEN:"
say "  $CID_SERVER/d/demo/datasets/street-scenes        street photos with their boxes; Releases compares v1.0 and v1.1"
say "  $CID_SERVER/d/demo/datasets/city-sounds          recordings, clips, a PDF and tables; the CSV's rows changed"
say "  $CID_SERVER/d/demo/models/street-detector        a model, and the dataset it was trained on"
