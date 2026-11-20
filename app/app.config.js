// Wraps app.json. Adds the Google Maps Android key from the environment (EAS environment variable / local .env) - never hard-coded.
module.exports = ({ config }) => {
  const key = process.env.GOOGLE_MAPS_ANDROID_KEY;
  if (!key) return config;
  return { ...config, android: { ...config.android, config: { ...(config.android && config.android.config), googleMaps: { apiKey: key } } } };
};
