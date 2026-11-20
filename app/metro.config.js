// Metro (phone bundler) configuration.
// Only addition to the Expo default: on phones, imports of 'react-native' from src/ go through src/rnshim/rn-shim.tsx
// so that Text and TextInput get the app font (Arial Black / the closest system font) by default.
// Everything inside src/rnshim/ must get the REAL react-native (Metro caches the answer per folder, so the shim
// lives in a folder of its own, otherwise it would be redirected to itself and the phone app would crash on start).
const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

const config = getDefaultConfig(__dirname);
const shim = path.join(__dirname, 'src', 'rnshim', 'rn-shim.tsx');
const norm = (p) => p.replace(/\\/g, '/').toLowerCase(); // Windows: slash and drive-letter case can differ
const srcDir = norm(path.join(__dirname, 'src')) + '/';
const shimDir = norm(path.join(__dirname, 'src', 'rnshim')) + '/';
const upstream = config.resolver.resolveRequest;

config.resolver.resolveRequest = (context, moduleName, platform) => {
  const from = norm(context.originModulePath);
  if (platform !== 'web' && moduleName === 'react-native' && from.startsWith(srcDir) && !from.startsWith(shimDir)) {
    return { type: 'sourceFile', filePath: shim };
  }
  return (upstream ?? context.resolveRequest)(context, moduleName, platform);
};

module.exports = config;