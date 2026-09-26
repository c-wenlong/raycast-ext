// Minimal stand-in for @raycast/api so the lib modules load under plain node.
const store = new Map();

exports.trash = async () => {};
exports.getPreferenceValues = () => ({});
exports.LocalStorage = {
  getItem: async (key) => store.get(key),
  setItem: async (key, value) => {
    store.set(key, value);
  },
};
