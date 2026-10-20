#include "task_sound.h"
#include <windows.h>
#include <mmsystem.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

bool PlayTaskCompletionSound() {
  // A short synthesized bell, independent of the music player and its mute.
  // Static storage keeps the PCM buffer alive for asynchronous WinMM playback.
  static const std::vector<char> wave = [] {
    constexpr int rate = 24000;
    constexpr int frames = 9120;
    std::vector<char> data(44 + frames * 2, 0);
    const auto put = [&data](int offset, uint32_t value, int bytes) {
      for (int i = 0; i < bytes; ++i) data[offset + i] = static_cast<char>((value >> (8 * i)) & 255);
    };
    std::copy_n("RIFF", 4, data.begin());
    put(4, static_cast<uint32_t>(data.size() - 8), 4);
    std::copy_n("WAVEfmt ", 8, data.begin() + 8);
    put(16, 16, 4); put(20, 1, 2); put(22, 1, 2);
    put(24, rate, 4); put(28, rate * 2, 4); put(32, 2, 2); put(34, 16, 2);
    std::copy_n("data", 4, data.begin() + 36);
    put(40, frames * 2, 4);
    for (int i = 0; i < frames; ++i) {
      const double t = static_cast<double>(i) / rate;
      const double angle = 6.283185307179586 * 1174.66 * t;
      const double envelope = (std::min)(t / .004, 1.0) * std::exp(-13 * t);
      const double bell = .72 * std::sin(angle) + .22 * std::sin(2.01 * angle) + .06 * std::sin(3.93 * angle);
      const auto sample = static_cast<int16_t>(18000 * envelope * bell);
      put(44 + i * 2, static_cast<uint16_t>(sample), 2);
    }
    return data;
  }();
  return PlaySoundA(wave.data(), nullptr, SND_MEMORY | SND_ASYNC | SND_NODEFAULT) != FALSE;
}
