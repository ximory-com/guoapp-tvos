package core

import (
    "context"
    "testing"
)

// A tvOS app can resume with a live Go engine whose old loopback listener is dead.
// Recovery must replace the server and invalidate the old playback session map.
func TestNativeStreamRecoverDeadListener(t *testing.T) {
    engine := &nativeEngine{downloader: &Downloader{}}
    defer func() {
        if engine.stream != nil {
            engine.stream.nativeShutdown("test_cleanup")
        }
    }()

    choice := nativePlaybackChoices(providerMedia{URL: "https://example.com/media.mp4"}, 0)
    first, err := engine.nativeOpenPlayback(context.Background(), choice)
    if err != nil { t.Fatalf("initial playback: %v", err) }
    old := engine.stream
    if old == nil || !old.nativeHealthy() {
        t.Fatal("initial loopback server is not healthy")
    }

    // Simulate the listener getting closed while its pointer survives.
    old.nativeShutdown("test_simulate_tvOS_suspend")
    if old.nativeHealthy() {
        t.Fatal("closed loopback listener still claims healthy")
    }

    second, err := engine.nativeOpenPlayback(context.Background(), choice)
    if err != nil { t.Fatalf("recover playback: %v", err) }
    if engine.stream == nil || engine.stream == old {
        t.Fatal("nativeOpenPlayback reused the dead stream listener")
    }
    if !engine.stream.nativeHealthy() {
        t.Fatal("replacement loopback server is unreachable")
    }
    if first.Session == second.Session {
        t.Fatal("recovery reused the stale playback token")
    }
    if _, exists := engine.playbacks[first.Session]; exists {
        t.Fatal("stale playback session survived the listener reset")
    }
    if _, exists := engine.playbacks[second.Session]; !exists {
        t.Fatal("new playback session missing after rebind")
    }
}
