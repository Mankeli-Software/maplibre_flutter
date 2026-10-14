# Keeps the Apple compile and link flags identical from one configure to the next.
#
# native_toolchain_cmake configures macOS and iOS with leetal's ios.toolchain.cmake,
# and that toolchain PREPENDS its flags to the current value of the same variable:
#
#   set(CMAKE_C_FLAGS "${C_TARGET_FLAGS} ${APPLE_TARGET_TRIPLE_FLAG} … ${VISIBILITY}
#       ${CMAKE_C_FLAGS}" CACHE INTERNAL …)
#   set(CMAKE_C_FLAGS_RELEASE "-DNDEBUG -O3 ${CMAKE_C_FLAGS_RELEASE}")
#
# likewise for CXX, OBJC, OBJCXX, the other build types and the *_LINK_FLAGS (ASM is
# C plus a suffix). CMake reads a toolchain twice on a build dir's first configure
# (system detection, then CMakeSystem.cmake) and once on every later one, so:
#
#  - the cached CMAKE_<LANG>_FLAGS and *_LINK_FLAGS get the prefix twice on a fresh
#    dir and one more copy on EVERY reconfigure, so they grow without end; and
#  - the per-build-type flags (plain variables) are "prefix prefix" on a fresh dir
#    but "prefix <CMake's cached default>" on a reconfigure.
#
# native_toolchain_cmake reconfigures on every hook run, so each run changed every
# object's command line and ninja/ccache rebuilt all of mbgl-core (~500 objects);
# one dev build dir had reached 67 copies of `-target … -fvisibility=default`.
#
# mfc_toolchain_flags_before_project() puts each cached variable back to its starting
# value (the user's own flags, normally none), and mfc_toolchain_flags_after_project()
# rewrites every result into one fixed shape: prefix, prefix, the user's own flags,
# which is exactly what a fresh configure produces when no flags are passed (the hook
# passes none). Every configure, first or fifth, then yields the same command lines,
# and build dirs that had only been configured once keep theirs. A cached value that
# differs from what the last configure left (a new -DCMAKE_C_FLAGS=…) becomes the new
# starting value rather than being dropped.
#
# Only this toolchain needs any of this: native_toolchain_cmake's Linux toolchains set
# their flags outright, and the Android NDK and vcpkg toolchains use the *_INIT
# variables, so elsewhere both functions do nothing and MFC_TOOLCHAIN_LANGUAGES is
# empty.

# The cached variables the toolchain prepends to.
set(_mfc_cached_flags
  CMAKE_C_FLAGS CMAKE_CXX_FLAGS CMAKE_OBJC_FLAGS CMAKE_OBJCXX_FLAGS
  CMAKE_C_LINK_FLAGS CMAKE_CXX_LINK_FLAGS CMAKE_OBJC_LINK_FLAGS CMAKE_OBJCXX_LINK_FLAGS)
# The plain variables it prepends to (their cache entries are CMake's own).
set(_mfc_per_config_flags)
foreach(_lang C CXX OBJC OBJCXX)
  foreach(_config DEBUG MINSIZEREL RELWITHDEBINFO RELEASE)
    list(APPEND _mfc_per_config_flags CMAKE_${_lang}_FLAGS_${_config})
  endforeach()
endforeach()

function(_mfc_prepending_toolchain out)
  if(CMAKE_TOOLCHAIN_FILE MATCHES "ios\\.toolchain\\.cmake$")
    set(${out} TRUE PARENT_SCOPE)
  else()
    set(${out} FALSE PARENT_SCOPE)
  endif()
endfunction()

# Splits `value` = <prefix repeated n times><tail> and returns one <prefix> in `out`,
# or "" when `value` does not end in `tail` or nothing precedes it.
function(_mfc_single_prefix value tail out)
  set(${out} "" PARENT_SCOPE)
  string(LENGTH "${value}" _value_len)
  string(LENGTH "${tail}" _tail_len)
  math(EXPR _len "${_value_len} - ${_tail_len}")
  if(_len LESS_EQUAL 0)
    return()
  endif()
  string(SUBSTRING "${value}" ${_len} -1 _actual_tail)
  if(NOT _actual_tail STREQUAL tail)
    return()
  endif()
  string(SUBSTRING "${value}" 0 ${_len} _prefix)
  # Halve while the two halves are equal: two reads leave the prefix twice.
  while(TRUE)
    string(LENGTH "${_prefix}" _len)
    math(EXPR _half "${_len} / 2")
    math(EXPR _odd "${_len} % 2")
    if(_half EQUAL 0 OR _odd EQUAL 1)
      break()
    endif()
    string(SUBSTRING "${_prefix}" 0 ${_half} _first)
    string(SUBSTRING "${_prefix}" ${_half} -1 _second)
    if(NOT _first STREQUAL _second)
      break()
    endif()
    set(_prefix "${_first}")
  endwhile()
  set(${out} "${_prefix}" PARENT_SCOPE)
endfunction()

# Call between cmake_minimum_required() and project(). Sets MFC_TOOLCHAIN_LANGUAGES
# to the languages project() must enable alongside C and CXX: the per-language
# flags are only all in place, to be fixed up, once every language is enabled.
function(mfc_toolchain_flags_before_project)
  set(MFC_TOOLCHAIN_LANGUAGES "" PARENT_SCOPE)
  _mfc_prepending_toolchain(_prepending)
  if(NOT _prepending)
    return()
  endif()
  set(MFC_TOOLCHAIN_LANGUAGES OBJC OBJCXX PARENT_SCOPE)
  foreach(_v IN LISTS _mfc_cached_flags)
    if(DEFINED CACHE{_MFC_FLAGS_OUT_${_v}}
        AND "$CACHE{${_v}}" STREQUAL "$CACHE{_MFC_FLAGS_OUT_${_v}}")
      # Untouched since the last configure wrote it: keep the starting value.
      set(_base "$CACHE{_MFC_FLAGS_BASE_${_v}}")
    elseif(NOT DEFINED CACHE{_MFC_FLAGS_OUT_${_v}} AND DEFINED CACHE{${_v}})
      get_property(_type CACHE ${_v} PROPERTY TYPE)
      if(_type STREQUAL "INTERNAL")
        # A build dir configured before this fix: the value is the toolchain's own
        # accumulated output, never a user's (that would be UNINITIALIZED or STRING).
        set(_base "")
      else()
        set(_base "$CACHE{${_v}}")
      endif()
    elseif(DEFINED CACHE{${_v}})
      # Changed since the last configure (-D…): the new starting value.
      set(_base "$CACHE{${_v}}")
    else()
      set(_base "")
    endif()
    set(_MFC_FLAGS_BASE_${_v} "${_base}" CACHE INTERNAL "")
    if(_base STREQUAL "")
      unset(${_v} CACHE)
    else()
      set(${_v} "${_base}" CACHE INTERNAL "")
    endif()
  endforeach()
  # What the toolchain will find in the per-build-type cache entries.
  foreach(_v IN LISTS _mfc_per_config_flags)
    set(_MFC_SEEN_${_v} "$CACHE{${_v}}" PARENT_SCOPE)
  endforeach()
endfunction()

# Call right after project(), before anything reads the flags.
function(mfc_toolchain_flags_after_project)
  _mfc_prepending_toolchain(_prepending)
  if(NOT _prepending)
    return()
  endif()
  set(_c_flags_as_produced "$CACHE{CMAKE_C_FLAGS}")
  foreach(_v IN LISTS _mfc_cached_flags)
    if(NOT DEFINED CACHE{${_v}})
      continue()
    endif()
    set(_base "$CACHE{_MFC_FLAGS_BASE_${_v}}")
    _mfc_single_prefix("$CACHE{${_v}}" "${_base}" _prefix)
    if(_prefix STREQUAL "")
      continue() # not the toolchain's doing; leave it exactly as it is
    endif()
    set(${_v} "${_prefix}${_prefix}${_base}" CACHE INTERNAL "")
    set(_MFC_FLAGS_OUT_${_v} "${_prefix}${_prefix}${_base}" CACHE INTERNAL "")
  endforeach()

  # ASM is set from CMAKE_C_FLAGS plus its own suffix, so it follows C.
  string(LENGTH "${_c_flags_as_produced}" _c_len)
  if(DEFINED CACHE{CMAKE_ASM_FLAGS} AND _c_len GREATER 0)
    set(_asm "$CACHE{CMAKE_ASM_FLAGS}")
    string(LENGTH "${_asm}" _asm_len)
    if(_asm_len GREATER_EQUAL _c_len)
      string(SUBSTRING "${_asm}" 0 ${_c_len} _asm_head)
      if(_asm_head STREQUAL _c_flags_as_produced)
        string(SUBSTRING "${_asm}" ${_c_len} -1 _asm_suffix)
        set(CMAKE_ASM_FLAGS "$CACHE{CMAKE_C_FLAGS}${_asm_suffix}" CACHE INTERNAL "")
      endif()
    endif()
  endif()

  # Per build type: the toolchain read the cache entry it found (none on a fresh
  # dir, CMake's default on a later one) and prepended to it. A fresh configure
  # never sees CMake's default, so it does not count as the user's own flags.
  foreach(_v IN LISTS _mfc_per_config_flags)
    if(NOT DEFINED _MFC_SEEN_${_v})
      continue()
    endif()
    set(_seen "${_MFC_SEEN_${_v}}")
    if("${${_v}}" STREQUAL "$CACHE{${_v}}")
      continue() # no plain variable from the toolchain to fix up
    endif()
    _mfc_single_prefix("${${_v}}" "${_seen}" _prefix)
    if(_prefix STREQUAL "")
      continue()
    endif()
    string(STRIP "${${_v}_INIT}" _default)
    if(_seen STREQUAL _default)
      set(_seen "")
    endif()
    set(${_v} "${_prefix}${_prefix}${_seen}" PARENT_SCOPE)
  endforeach()
endfunction()
