# Activity monitoring

Planned; not implemented. Will use the [shared group data pipeline](group.md#shared-data-pipeline) with an independent sharing control and its own feature identifier.

Define activity events and update frequency, then verify client support. Reuse the common data channel rather than creating another feature-specific channel. Delivery is limited to the [validated internal-realm scope](position-sharing.md#connection-and-limits); cross-internal-realm delivery and whisper fallback remain unsupported, independently of human chat.

Use WoW's supplied sender and define the feature's payload and ordering rules. The shared pipeline does not implement activity monitoring or establish live delivery.
