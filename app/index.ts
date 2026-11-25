import { registerRootComponent } from 'expo';

import './src/lib/webAlert';
import './src/lib/webScroll';   // web / desktop only: four-direction scrolling (does nothing on the phone)
import App from './App';

// registerRootComponent calls AppRegistry.registerComponent('main', () => App);
// It also ensures that whether you load the app in Expo Go or in a native build,
// the environment is set up appropriately
registerRootComponent(App);
