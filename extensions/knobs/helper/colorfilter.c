// Controls the macOS grayscale color filter via private MediaAccessibility SPI.
// Build: npm run build-helper (outputs to assets/colorfilter)
//
// usage: colorfilter [get|toggle|set <0-100>]
//   get         print current grayscale level (0 when filter is off)
//   toggle      0 if current level > 0, otherwise 100
//   set <n>     set grayscale to n%, 0 turns the filter off
// Prints the resulting level on stdout.

#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CATEGORY_COLOR 1
#define TYPE_GRAYSCALE 1

typedef int (*get_enabled_t)(int);
typedef void (*set_enabled_t)(int, int);
typedef long (*get_type_t)(int);
typedef void (*set_type_t)(int, long);
typedef double (*get_intensity_t)(void);
typedef void (*set_intensity_t)(double);

int main(int argc, char *argv[]) {
  void *h = dlopen("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility", RTLD_NOW);
  if (!h) {
    fprintf(stderr, "failed to load MediaAccessibility framework\n");
    return 1;
  }
  get_enabled_t getEnabled = (get_enabled_t)dlsym(h, "MADisplayFilterPrefGetCategoryEnabled");
  set_enabled_t setEnabled = (set_enabled_t)dlsym(h, "MADisplayFilterPrefSetCategoryEnabled");
  get_type_t getType = (get_type_t)dlsym(h, "MADisplayFilterPrefGetType");
  set_type_t setType = (set_type_t)dlsym(h, "MADisplayFilterPrefSetType");
  get_intensity_t getIntensity = (get_intensity_t)dlsym(h, "MADisplayFilterPrefGetGrayscaleCorrectionIntensity");
  set_intensity_t setIntensity = (set_intensity_t)dlsym(h, "MADisplayFilterPrefSetGrayscaleCorrectionIntensity");
  if (!getEnabled || !setEnabled || !getType || !setType || !getIntensity || !setIntensity) {
    fprintf(stderr, "missing MediaAccessibility symbols\n");
    return 1;
  }

  int current = 0;
  if (getEnabled(CATEGORY_COLOR) && getType(CATEGORY_COLOR) == TYPE_GRAYSCALE)
    current = (int)lround(getIntensity() * 100.0);

  const char *cmd = argc > 1 ? argv[1] : "toggle";
  if (strcmp(cmd, "get") == 0) {
    printf("%d\n", current);
    return 0;
  }

  int target;
  if (strcmp(cmd, "toggle") == 0) {
    target = current > 0 ? 0 : 100;
  } else if (strcmp(cmd, "set") == 0 && argc > 2) {
    char *end;
    long v = strtol(argv[2], &end, 10);
    if (*end != '\0' || v < 0 || v > 100) {
      fprintf(stderr, "level must be an integer 0-100\n");
      return 2;
    }
    target = (int)v;
  } else {
    fprintf(stderr, "usage: colorfilter [get|toggle|set <0-100>]\n");
    return 2;
  }

  if (target == 0) {
    setEnabled(CATEGORY_COLOR, 0);
  } else {
    setType(CATEGORY_COLOR, TYPE_GRAYSCALE);
    setIntensity(target / 100.0);
    setEnabled(CATEGORY_COLOR, 1);
  }
  printf("%d\n", target);
  return 0;
}
