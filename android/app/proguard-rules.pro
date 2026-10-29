# Project-specific R8/ProGuard rules.
# The default `proguard-android-optimize.txt` rules are supplied by AGP in
# android/app/build.gradle; Flutter and its plugins contribute their own keep
# rules, so nothing extra is required here today.
#
# Add rules only for code R8 genuinely cannot see:
#   - reflection targets (e.g. Class.forName("..."))
#   - security providers loaded by class name
#   - serialised model classes whose field names are part of the wire format
