enum RidingDisplaySize {
  small('Small', 1),
  medium('Medium', 1.3),
  large('Large', 1.65);

  const RidingDisplaySize(this.label, this.scale);
  final String label;
  final double scale;
}
