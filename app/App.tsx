import './src/lib/globalFont'; // must load first: sets the default font (Arial Black) for all text
import { StatusBar } from 'expo-status-bar';
import React, { useEffect, useState } from 'react';
import { ActivityIndicator, Text, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import LiveTracker from './src/components/LiveTracker';
import RasterHost from './src/components/RasterHost';
import ReleaseWatcher from './src/components/ReleaseWatcher';
import { loadServerConfig, onServerChange } from './src/config';
import { AuthProvider } from './src/lib/auth';
import { useAutoUpdate } from './src/lib/otaUpdate';
import { setupPwa } from './src/lib/pwa';
import { resetSupabase } from './src/lib/supabase';
import RootNavigator from './src/navigation';

setupPwa(); // web: installable as a desktop app, always loads the newest files

// Shows the error on screen instead of a blank white page
class ErrorBoundary extends React.Component<{ children: React.ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  render() {
    if (!this.state.error) return this.props.children;
    return (
      <View style={{ flex: 1, padding: 24, backgroundColor: '#FFF5F5' }}>
        <Text style={{ fontWeight: '800', fontSize: 16, color: '#B42318', marginBottom: 8 }}>The app hit an error</Text>
        <Text selectable style={{ color: '#1F2937', fontSize: 13 }}>{String(this.state.error?.message ?? this.state.error)}</Text>
        <Text selectable style={{ color: '#6B7280', fontSize: 11, marginTop: 10 }}>{String(this.state.error?.stack ?? '').slice(0, 1200)}</Text>
      </View>
    );
  }
}

export default function App() {
  const [ready, setReady] = useState(false);
  const [rev, setRev] = useState(0);

  // 1. read the server address saved on this device (office server or internet)   2. reconnect when it is changed
  useEffect(() => {
    loadServerConfig().finally(() => setReady(true));
    return onServerChange(() => { resetSupabase(); setRev((r) => r + 1); });
  }, []);

  useAutoUpdate();   // phone: take a newer version as soon as the app opens (see src/lib/otaUpdate.ts)

  if (!ready) {
    return <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: '#F5F8FC' }}><ActivityIndicator color="#0A7CFF" /></View>;
  }
  return (
    <SafeAreaProvider key={rev}>
      <ErrorBoundary>
        <AuthProvider>
          <StatusBar style="dark" />
          <ReleaseWatcher />
          <RasterHost />
          <LiveTracker />
          <RootNavigator />
        </AuthProvider>
      </ErrorBoundary>
    </SafeAreaProvider>
  );
}