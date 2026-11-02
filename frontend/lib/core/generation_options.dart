class GenerationOptions {
  const GenerationOptions({
    required this.style,
    required this.aspectRatio,
    required this.quality,
  });

  final String style;
  final String aspectRatio;
  final String quality;

  bool get isPremium {
    return style == animeStyle || style == cinematicStyle || quality == hdQuality;
  }

  GenerationOptions copyWith({
    String? style,
    String? aspectRatio,
    String? quality,
  }) {
    return GenerationOptions(
      style: style ?? this.style,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      quality: quality ?? this.quality,
    );
  }
}

const String photorealisticStyle = 'photorealistic';
const String digitalArtStyle = 'digital-art';
const String animeStyle = 'anime';
const String cinematicStyle = 'cinematic';
const String squareAspectRatio = '1:1';
const String portraitAspectRatio = '2:3';
const String wideAspectRatio = '16:9';
const String standardQuality = 'standard';
const String hdQuality = 'hd';
const GenerationOptions freeGenerationOptions = GenerationOptions(
  style: photorealisticStyle,
  aspectRatio: squareAspectRatio,
  quality: standardQuality,
);

String labelForStyle(String style) {
  switch (style) {
    case photorealisticStyle:
      return 'Photorealistic';
    case digitalArtStyle:
      return 'Digital Art';
    case animeStyle:
      return 'Anime';
    case cinematicStyle:
      return 'Cinematic';
    default:
      return style;
  }
}

String labelForQuality(String quality) {
  switch (quality) {
    case standardQuality:
      return 'Standard';
    case hdQuality:
      return 'HD';
    default:
      return quality;
  }
}
