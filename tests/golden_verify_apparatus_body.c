
	
#if defined(__cplusplus)
static_assert(
  std::is_same<
    typename softlink_strip_ptr_const<decltype(softlink_golden_add(softlinkP_1, softlinkP_2))>::type,
    int>::value,
  "softlink: softlink_golden_add signature mismatch vs tests/testlib_golden.h"
);
#elif defined(__GNUC__)
_Static_assert(
  __builtin_types_compatible_p(
    __typeof__(softlink_golden_add(softlinkP_1, softlinkP_2)),
    int),
  "softlink: softlink_golden_add signature mismatch vs tests/testlib_golden.h"
);
#elif defined(_MSC_VER) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
softlink_golden_add(softlinkP_1, softlinkP_2);
_Static_assert(
  _Generic((__typeof__(softlink_golden_add(softlinkP_1, softlinkP_2))*)0,
    int*: 1, default: 0),
  "softlink: softlink_golden_add signature mismatch vs tests/testlib_golden.h"
);
#else
/* softlink: signature verification skipped — unsupported compiler/mode */
#endif

	