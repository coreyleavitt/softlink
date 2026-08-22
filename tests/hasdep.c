/* RFC 0011 S0a item 5, story (c): links against libstubdep.so (see
 * stubdep.c) so the resulting libhasdep.so carries a DT_NEEDED entry that
 * cannot resolve once libstubdep.so is deleted post-link. */
extern int stubdep_func(void);

int hasdep_func(void) {
  return stubdep_func();
}
