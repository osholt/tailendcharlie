enum RideLibraryStatus {
  active,
  archived,
  deleted;

  static RideLibraryStatus parse(Object? value) =>
      values.where((status) => status.name == value).firstOrNull ?? active;
}
