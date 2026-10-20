#include "task_sound.h"
#include <windows.h>
#include <mmsystem.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {
struct Note { double start, frequency, duration; };
std::vector<char> MakeWave(const std::vector<Note>& notes, double seconds) {
    constexpr int rate = 48000;
    const int frames = static_cast<int>(seconds * rate);
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
      double value = 0;
      for (const auto& note : notes) {
        const double t = static_cast<double>(i) / rate - note.start;
        if (t < 0 || t >= note.duration) continue;
        const double angle = 6.283185307179586 * note.frequency * t;
        const double envelope = (std::min)(t / .0007, 1.0) * std::exp(-10 * t) * (std::min)((note.duration - t) / .015, 1.0);
        value += 30000 * envelope * (.58 * std::sin(angle) + .29 * std::sin(2.01 * angle) + .13 * std::sin(3.93 * angle));
      }
      const auto sample = static_cast<int16_t>((std::clamp)(value, -32760.0, 32760.0));
      put(44 + i * 2, static_cast<uint16_t>(sample), 2);
    }
    return data;
}
bool Play(const std::vector<char>& wave) {
  return PlaySoundA(wave.data(), nullptr, SND_MEMORY | SND_ASYNC | SND_NODEFAULT) != FALSE;
}
}
bool PlayTaskCompletionSound() {
  // Static buffers survive asynchronous playback. Higher harmonics, a faster
  // attack and a stronger peak make the task bell clearer and more present.
  static const auto wave = MakeWave({{0, 1567.98, .42}}, .42);
  return Play(wave);
}
bool PlayTimerSound(bool rest_finished) {
  static const auto focus = MakeWave({{0, 880, .20}, {.25, 1318.51, .25}}, .50);
  static const auto rest = MakeWave({{0, 1318.51, .16}, {.20, 1046.5, .16}, {.40, 783.99, .22}}, .62);
  return Play(rest_finished ? rest : focus);
}
