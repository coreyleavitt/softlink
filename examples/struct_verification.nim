## Example: Compile-time struct layout verification with dyntype
##
## Demonstrates how to verify that Nim struct definitions match C header
## layouts at compile time. This catches size mismatches (wrong fields,
## wrong types, missing padding) before they cause silent memory corruption
## when passing structs to dynamically loaded C functions.

import softlink

# --- Verify struct layouts against a C header ---
#
# The C header defines the "ground truth" layout. The Nim types are
# independent definitions that must match. dyntype emits
# _Static_assert(sizeof(NimType) == sizeof(CType)) at C compile time.

dyntype "tests/testlib_types.h":
  type Point {.ctype: "testlib_point_t".} = object
    x: cint
    y: cint

  type Rect {.ctype: "testlib_rect_t".} = object
    origin: Point
    width: cint
    height: cint

  type TaggedValue {.ctype: "testlib_tagged_value_t".} = object
    value: cdouble
    flags: cint

# --- Use the verified types normally ---
#
# These types are plain Nim objects — no {.importc.}, no C dependency
# at runtime. The compile-time sizeof check ensures they're safe to pass
# to any C function expecting the corresponding C struct.

when isMainModule:
  var p = Point(x: 10, y: 20)
  echo "Point: (", p.x, ", ", p.y, ") — sizeof = ", sizeof(Point)

  var r = Rect(origin: p, width: 640, height: 480)
  echo "Rect: origin=(", r.origin.x, ", ", r.origin.y,
       ") size=", r.width, "x", r.height,
       " — sizeof = ", sizeof(Rect)

  var tv = TaggedValue(value: 3.14, flags: 1)
  echo "TaggedValue: ", tv.value, " [flags=", tv.flags,
       "] — sizeof = ", sizeof(TaggedValue)

  echo "\nAll struct layouts verified against C headers at compile time."
