// Minimal stand-in for @raycast/api so the lib modules load under plain node.
// Only what src/lib touches; the tests pass explicit paths, so assetsPath is
// never used to find a real binary.
exports.environment = { assetsPath: "/nonexistent/focus-assets" };
exports.getPreferenceValues = () => ({});
