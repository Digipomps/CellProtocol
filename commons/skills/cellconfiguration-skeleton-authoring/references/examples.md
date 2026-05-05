# Examples

## Minimal `CellConfiguration`

```json
{
  "name": "Test Config",
  "cellReferences": [
    {
      "endpoint": "cell:///Example",
      "label": "example",
      "subscribeFeed": true,
      "subscriptions": [],
      "setKeysAndValues": [
        { "key": "example.set", "value": "hello" }
      ]
    }
  ],
  "skeleton": {
    "Text": { "text": "Hello" }
  }
}
```

## Minimal `Text`

```json
{
  "Text": { "text": "Hello" }
}
```

## `List` with `flowElementSkeleton`

```json
{
  "List": {
    "flowElementSkeleton": {
      "VStack": [
        { "Text": { "text": "Item" } }
      ]
    }
  }
}
```

## Safe authoring pattern

Når en bruker ber om en mer avansert UI:

1. kartlegg hvilke deler som kan uttrykkes med dagens elementer
2. kall ut det som mangler eksplisitt
3. ikke finn opp nye elementer

Eksempel på riktig responsmønster:

- `Supported now:` `VStack`, `Text`, `Button`, `List`, `Grid`, `Toggle`
- `Not supported in current skeleton:` filopplasting, innebygd video, ny custom chart
- `Needs Kjetil approval before implementation:` nytt `FileUpload`-element
