htmx.onLoad(function(content) {
  var sortables = content.querySelectorAll(".sortable");
  for (let i = 0; i < sortables.length; i++) {
    let sortable = sortables[i];
    new Sortable(sortable, {
      animation: 150,
    });
  }
})
