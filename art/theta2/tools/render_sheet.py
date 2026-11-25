"""Render a contact sheet of poses: blender -b THETA2_game.blend --python render_sheet.py -- outdir act:frame:view ..."""
import bpy, sys, os
from mathutils import Vector
argv = sys.argv[sys.argv.index("--") + 1:]
outdir = argv[0]
skel = bpy.data.objects["THETA_Skeleton"]
skel.animation_data_create()
sc = bpy.context.scene
cam = bpy.data.objects["Camera"]
sc.camera = cam
cam.data.type = "PERSP"; cam.data.lens = 50
sc.render.resolution_x = int(os.environ.get("RW", 360)); sc.render.resolution_y = int(os.environ.get("RH", 460))
VIEWS = {"side": Vector((3.4, 0, 1.0)), "front": Vector((0, -3.6, 1.1)), "q": Vector((2.5, -2.5, 1.3)),
         "back": Vector((0, 3.6, 1.1)), "top": Vector((0.8, -1.2, 3.2)), "fr": Vector((-1.4, -2.0, 1.5)), "rside": Vector((-2.2, 0, 1.4))}
for spec in argv[1:]:
    act, frame, view = spec.split(":")
    for pb in skel.pose.bones:
        pb.matrix_basis.identity()
    a = bpy.data.actions[act]
    skel.animation_data.action = a
    if a.slots:
        skel.animation_data.action_slot = a.slots[0]
    sc.frame_set(int(float(frame)))
    pos = VIEWS[view]; tgt = Vector((0, 0, 0.95))
    cam.location = pos
    cam.rotation_euler = (tgt - pos).to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = os.path.join(outdir, f"{act}_{frame}_{view}.png")
    bpy.ops.render.render(write_still=True)

# ---- compose into one sheet (numpy ships with Blender)
import numpy as np
files = [os.path.join(outdir, "{}_{}_{}.png".format(*s.split(":"))) for s in argv[1:]]
imgs = []
for f in files:
    im = bpy.data.images.load(f)
    w, h = im.size
    px = np.array(im.pixels[:], dtype=np.float32).reshape(h, w, 4)
    imgs.append(px)
cols = min(5, len(imgs))
rows = (len(imgs) + cols - 1) // cols
h, w = imgs[0].shape[:2]
sheet = np.ones((rows * h, cols * w, 4), dtype=np.float32)
for i, px in enumerate(imgs):
    r, c = divmod(i, cols)
    r = rows - 1 - r  # blender images are bottom-up
    sheet[r * h:(r + 1) * h, c * w:(c + 1) * w] = px
out = bpy.data.images.new("sheet", cols * w, rows * h, alpha=True)
out.pixels = sheet.ravel()
out.filepath_raw = os.path.join(outdir, "sheet.png")
out.file_format = "PNG"
out.save()
print("sheet", out.filepath_raw)
