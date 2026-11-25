"""Helpers to pose THETA_Skeleton with rotations given in armature (character) axes.

Character axes (Blender): +X = character's left, -Y = forward, +Z = up.
rot(bone, x=deg, y=deg, z=deg) rotates the bone (and its children) about its head, with the
angles measured around the character's X/Y/Z axes *in the parent's current frame*.
  Sign notes (right-hand rule around +X = left):
    leg pointing down : x<0 swings the foot forward (thigh raise), x>0 swings it back (knee bend)
    spine pointing up : x>0 leans forward, x<0 leans back
    z>0 turns the character to its left (yaw)
"""
import bpy
from mathutils import Euler, Quaternion, Matrix, Vector
import math


def arm_quat(x=0.0, y=0.0, z=0.0):
    return Euler((math.radians(x), math.radians(y), math.radians(z)), "XYZ").to_quaternion()


def set_rot(skel, name, x=0.0, y=0.0, z=0.0, q=None):
    pb = skel.pose.bones[name]
    rest = pb.bone.matrix_local.to_quaternion()
    qa = q if q is not None else arm_quat(x, y, z)
    pb.rotation_mode = "QUATERNION"
    pb.rotation_quaternion = rest.inverted() @ qa @ rest


def reset(skel):
    for pb in skel.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = Quaternion()
        pb.location = Vector()
        pb.scale = Vector((1, 1, 1))


def set_loc(skel, name, offset):
    """Move a bone by an offset given in armature axes."""
    pb = skel.pose.bones[name]
    rest = pb.bone.matrix_local.to_quaternion()
    pb.location = rest.inverted() @ Vector(offset)


def key(skel, frame, names=None):
    for pb in skel.pose.bones:
        if names is not None and pb.name not in names:
            continue
        pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)
        if pb.name in ("root", "DEF-spine"):
            pb.keyframe_insert("location", frame=frame, group=pb.name)
