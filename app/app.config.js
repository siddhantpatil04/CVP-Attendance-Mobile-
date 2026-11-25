// Wraps app.json.
//  - Adds the Google Maps Android key from the environment (EAS environment variable / local .env) - never hard-coded.
//  - Uses google-services.json (Firebase, phone notifications) only when the file is in this folder, so the web / desktop build works without it.
const fs = require('fs');
const path = require('path');
module.exports = ({ config }) => {
  const android = { ...(config.android || {}) };
  const key = process.env.GOOGLE_MAPS_ANDROID_KEY;
  if (key) android.config = { ...(android.config || {}), googleMaps: { apiKey: key } };
  if (fs.existsSync(path.join(__dirname, 'google-services.json'))) android.googleServicesFile = './google-services.json';
  return { ...config, android };
};
