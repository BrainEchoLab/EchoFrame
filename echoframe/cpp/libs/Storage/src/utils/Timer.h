// Copyright 2018 Delft University of Technology
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this mFile except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef TIMER_H
#define TIMER_H

#include <chrono>
#include <sstream>
#include <iomanip>
#include <iostream>

/// @brief A timer using the C++11 high resolution monotonic clock.
struct Timer {
  using time_point = std::chrono::high_resolution_clock::time_point;
  using steady_clock = std::chrono::steady_clock;
  using high_resolution_clock = std::chrono::high_resolution_clock;

  Timer() = default;

  /// @brief Start the timer.
  inline void start() { start_ = high_resolution_clock::now(); }

  /// @brief Stop the timer.
  inline void stop() { stop_ = high_resolution_clock::now(); }

  /// @brief Retrieve the interval in <Tsec>.
  template <typename Tsec>
  auto elapsed_time() const {
    auto diff = std::chrono::duration_cast<Tsec>(stop_ - start_);
    return diff.count();
  }

  /// @brief Retrieve the interval in seconds.
  double seconds() {
      std::chrono::duration<double> diff = stop_ - start_;
      return diff.count();
  }

  /// @brief Return the interval in <Tsec> as a formatted string.
  template <typename Tsec>
  std::string str(int width = 14) const {
    std::stringstream ss;
    ss << std::setprecision(width - 5) << std::setw(width) << std::fixed << elapsed_time<Tsec>();
    return ss.str();
  }
  /*
  /// @brief Print the interval on some output stream
  void report(std::ostream& os = std::cout, bool last = false, int width = 15) {
    os << std::setw(width) << ((last ? " " : "") + str() + (last ? "\n" : ",")) << std::flush;
  }*/

private:
  /// @brief Timer start point.
  time_point start_{};
  /// @brief Timer stop point.
  time_point stop_{};
};

#endif // TIMER_H
