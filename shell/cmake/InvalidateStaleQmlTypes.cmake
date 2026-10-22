# Run as a build step before the QML module target (see shell/CMakeLists.txt, T-116).
#
# Visual Studio generators put "collect metatypes JSON" and "run qmltyperegistrar" in ONE
# MSBuild CustomBuild batch. MSBuild decides what is out of date before the batch runs, so the
# registrar does not see the fresh JSON produced by the first rule and is skipped. The stale
# registration .cpp and .qmltypes then cause "X is not defined" (tests) and "Member not found"
# (qmllint) on the first build after a type was added or changed, and a compile error after one
# was removed. Deleting the registrar outputs when an input is newer than them makes MSBuild
# schedule the rule (a missing output is always out of date).
#
# Arguments: -DINPUTS=<a|b|c> -DOUTPUTS=<x|y>  ('|' separated; the first output is the reference).
# INPUTS are CMakeLists.txt (types added, removed, renamed) and the module's headers (edited).
string(REPLACE "|" ";" INPUTS "${INPUTS}")
string(REPLACE "|" ";" OUTPUTS "${OUTPUTS}")

list(GET OUTPUTS 0 reference)
if(NOT EXISTS "${reference}")
    return()   # nothing generated yet: the first build creates everything
endif()

foreach(input IN LISTS INPUTS)
    # IS_NEWER_THAN is true for a missing file, which would invalidate on every build.
    if(EXISTS "${input}" AND "${input}" IS_NEWER_THAN "${reference}")
        message(STATUS "ruyashell: ${input} is newer than the QML type registration; regenerating it")
        file(REMOVE ${OUTPUTS})
        return()
    endif()
endforeach()
