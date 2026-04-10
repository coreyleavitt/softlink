#ifndef TESTLIB_TYPES_H
#define TESTLIB_TYPES_H

typedef struct {
    int x;
    int y;
} testlib_point_t;

typedef struct {
    testlib_point_t origin;
    int width;
    int height;
} testlib_rect_t;

typedef struct {
    double value;
    int flags;
} testlib_tagged_value_t;

#endif
