# Navigation bar icons

`SkeletonNavigationBarItem.icon` is an optional SF Symbol name, using the same
convention as `SkeletonButton.icon`. It is encoded inside each item of the existing
`{"NavigationBar":{"items":[...]}}` wrapper. Missing or null icons decode as nil;
nil is omitted when encoding. Existing text-only items remain valid.

The native CellApple renderer places a non-empty icon above its visible label.
The icon is decorative for accessibility: the label names the control. Items
without an icon retain their previous subheadline text size. Active selection,
safe URL navigation, action keypaths and payload bindings are unchanged.

`asSkeletonButton()` preserves the icon and the action bindings. Web consumers
need a matching renderer update and their own SF Symbol mapping before claiming
icon parity. Unknown symbols must not replace or hide the visible text label.
This addition does not change localization support or introduce a new element.

The SkeletonTests navigation-bar fixtures cover wrapped round trips, omission on
legacy items, invalid field types and preservation of action bindings.
