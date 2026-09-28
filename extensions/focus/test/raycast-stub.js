// Minimal stand-in for @raycast/api so the lib modules load under plain node.
// Only what src/lib touches; the tests pass explicit paths, so assetsPath is
// never used to find a real binary.
exports.environment = { assetsPath: "/nonexistent/focus-assets" };
exports.getPreferenceValues = () => ({});
exports.getApplications = async () => [];

// In-memory LocalStorage with the async API Raycast has; `_reset` is for tests.
const localStore = new Map();
exports.LocalStorage = {
  getItem: async (key) => localStore.get(key),
  setItem: async (key, value) => {
    localStore.set(key, value);
  },
  removeItem: async (key) => {
    localStore.delete(key);
  },
  allItems: async () => Object.fromEntries(localStore),
  clear: async () => {
    localStore.clear();
  },
  _reset: () => localStore.clear(),
};
