# Home Assistant Custom Integration Patterns for Cairn NVR

**Research Date:** 2026-07-23  
**HA Versions Covered:** 2024–2026 (with recent July 2026 updates)  
**Focus:** Python API surface for media_source, push/real-time integration, and config flow + entity lifecycle

---

## 1. MEDIA BROWSER: `media_source` Platform & Frigate Model

### 1.1 MediaSource Base Class & Core Methods

**Documentation:** [Home Assistant Media Source Platform](https://developers.home-assistant.io/docs/core/platform/media_source/) [T1]

The `MediaSource` base class (from `homeassistant.components.media_source`) defines three methods:

```python
from homeassistant.components.media_source import MediaSource, BrowseMediaSource, PlayMedia

class MyMediaSource(MediaSource):
    name = "Cairn NVR"
    
    async def async_browse_media(self, item: MediaSourceItem) -> BrowseMediaSource:
        """Return browsable media tree at the given item."""
        if not item.identifier:
            # Root request: return top-level structure
            return BrowseMediaSource(
                domain="cairn",
                identifier=None,
                media_class=MediaClass.DIRECTORY,
                media_content_type="",
                title="Cairn Recordings",
                can_play=False,
                can_expand=True,
                children=[...]
            )
        # Parse identifier and return appropriate level
        return self._drill_down(item.identifier)
    
    async def async_resolve_media(self, item: MediaSourceItem) -> PlayMedia:
        """Resolve item to a playable clip with URL and MIME type."""
        url = f"https://cairn.local/api/clips/{item.identifier}"
        return PlayMedia(
            url=url,
            mime_type="video/mp4"
        )
    
    async def async_search_media(self, item: MediaSourceItem, query: str) -> BrowseMediaSource:
        """Optional: Enable user search across media."""
        # Filter by query and return filtered BrowseMediaSource
        pass
```

**Key Parameters:**

- `item.identifier` (str): URI-derived key identifying the requested item. `None` for root browse.
- `item.domain` (str | None): Integration namespace.
- `item.target_media_player` (str | None): Intended playback device.

### 1.2 BrowseMediaSource Structure

```python
from homeassistant.components.media_source import BrowseMediaSource, MediaClass

BrowseMediaSource(
    domain="cairn",                    # Your integration domain
    identifier="camera_1/2026-07-20",  # Item key; None for root
    media_class=MediaClass.DIRECTORY,  # DIRECTORY, VIDEO, IMAGE, MUSIC, APP
    media_content_type="",             # MIME or descriptor; "" for folders
    title="Porch Camera",              # User-facing label
    can_play=False,                    # Can this item play directly?
    can_expand=True,                   # Does it have children?
    children=[...],                    # Child BrowseMediaSource list
    thumbnail="https://...",           # Optional image URL
    can_search=False                   # (HA 2026.7+) Search enabled at level?
)
```

**MediaClass enum:** `DIRECTORY`, `VIDEO`, `IMAGE`, `MUSIC`, `APP`

### 1.3 PlayMedia: Returning Playable URLs with Authentication

```python
from homeassistant.components.media_source import PlayMedia

return PlayMedia(
    url="https://cairn.local/api/clips/event-123/stream.m3u8",
    mime_type="application/vnd.apple.mpegurl"  # HLS
)
# OR for MP4:
# mime_type="video/mp4"
```

**URL Authentication Strategy (from Frigate model):**

- All clip URLs proxy through the HA integration endpoint: `/api/frigate/{instance_id}/{resource_path}`
- Security handled by HA's built-in auth layer; no explicit token in URL construction needed
- For direct external URLs, embed auth tokens in query params or use bearer headers if HA acts as reverse proxy

### 1.4 Frigate Integration: Reference Model

**Source:** [Frigate Media Source Implementation](https://github.com/blakeblackshear/frigate-hass-integration/blob/master/custom_components/frigate/media_source.py) [T3]

**Frigate's hierarchy pattern:**

```
Root → Clips / Recordings / Snapshots (by instance)
      → Events / Dates / Cameras / Labels / Zones (drill-down dimensions)
      
RecordingIdentifier structure:
  /api/frigate/{frigate_instance_id}/vod/{camera}/start/{padded_start}/end/{padded_end}/index.m3u8
  
Padding: DEFAULT_VOD_EVENT_PADDING = 10 seconds (configurable)
If end_time missing (in-progress events): use current timestamp
```

**Key Frigate patterns for Cairn:**

1. **Identifier Serialization:** All identifiers convert to/from slash-delimited strings for persistence:
   ```python
   # Example: "porch/2026-07-20/10-30-45" → EventIdentifier(camera="porch", date="2026-07-20", event_id="...")
   # Use immutable identifier classes with from_str() parsers
   ```

2. **Lazy Filtering:** Aggregate all events/recordings once, then filter dynamically for drill-down options (don't fetch per-level).

3. **Item Limiting:** Support `.all` suffix to retrieve unlimited items (default limit ~50).

4. **Permissions:** Gate media source access via `CONF_MEDIA_BROWSER_ENABLE` in config entry options.

---

## 2. PUSH/REAL-TIME INTEGRATION: WebSocket + State Updates

### 2.1 DataUpdateCoordinator vs Custom Push Coordinator

**Documentation:** [Integration Fetching Data](https://developers.home-assistant.io/docs/integration_fetching_data/) [T1]

**Use DataUpdateCoordinator when:**
- One API endpoint serves **multiple entities**
- Data needs **periodic polling** at a consistent interval
- Automatic entity availability management via coordinator state

**Use custom push coordinator when:**
- You implement **socket/WebSocket listeners directly**
- Real-time **events arrive via subscriptions** (not polling)
- You manage reconnect/backoff **outside the poll loop**

For Cairn (persistent WebSocket + event push), use a **custom push coordinator or hybrid pattern**:

```python
class CairnEventCoordinator(DataUpdateCoordinator):
    """Hybrid: coordinator wraps WebSocket subscription."""
    
    def __init__(self, hass: HomeAssistant, cairn_client):
        super().__init__(hass, logger, name="Cairn Events", update_interval=None)
        self.cairn_client = cairn_client
        self._ws_task = None
    
    async def async_config_entry_first_refresh(self) -> None:
        """Called after config entry is set up; spawn WebSocket listener."""
        await self.hass.async_add_executor_job(self._start_ws_listener)
        await super().async_config_entry_first_refresh()
    
    def _start_ws_listener(self):
        """Spawn long-lived WebSocket listener in background."""
        async def listen_events():
            async for event in self.cairn_client.subscribe_events():
                self.async_set_updated_data(event)
                # Coordinator notifies all subscribed CoordinatorEntities
        
        self._ws_task = asyncio.create_task(listen_events())
    
    async def _async_update_data(self):
        """Fallback poll (optional); typically empty for push sources."""
        return await self.cairn_client.get_latest_state()
```

### 2.2 State Updates for Push APIs

**Do NOT use polling for push sources.** Instead:

1. **Disable default polling:** Set `_attr_should_poll = False` on all entities
   ```python
   class CairnMotionSensor(CoordinatorEntity, BinarySensorEntity):
       _attr_should_poll = False  # No default update_ha_state calls
       
       async def async_added_to_hass(self) -> None:
           """Subscribe to coordinator updates."""
           await super().async_added_to_hass()
           self.coordinator.async_add_listener(self._handle_coordinator_update)
       
       def _handle_coordinator_update(self) -> None:
           """Called when coordinator receives push event."""
           event_data = self.coordinator.data
           if self._matches_camera(event_data):
               self._attr_is_on = event_data["motion"]
               self.async_write_ha_state()  # Write without re-fetching
   ```

2. **Use `async_write_ha_state()`** to write state without calling `async_update()`:
   ```python
   # Push event arrives → parse → update internal state → write state
   self.async_write_ha_state()  # Efficient for push
   ```

3. **Alternative (manual state machine update):** Call `self.async_schedule_update_ha_state(force_refresh=False)` if you prefer entity's `async_update()` to run (less common for push).

### 2.3 Availability & Connection State

**CoordinatorEntity auto-manages availability:**

```python
class CairnEntity(CoordinatorEntity):
    @property
    def available(self) -> bool:
        """Entity is unavailable if coordinator has not updated recently."""
        return self.coordinator.last_update_success
```

**For explicit socket connection tracking:**

```python
class CairnEntity(Entity):
    @property
    def available(self) -> bool:
        """Custom availability tied to socket connection."""
        return self.coordinator.cairn_client.is_connected
    
    async def async_added_to_hass(self) -> None:
        """Subscribe to connection state changes."""
        self.coordinator.cairn_client.add_listener(
            lambda: self.async_write_ha_state()
        )
```

### 2.4 Reconnection & Backoff Patterns

**For push API failures in coordinator:**

```python
async def _async_update_data(self):
    """Fallback update or error handling."""
    try:
        return await self.cairn_client.fetch_state()
    except asyncio.TimeoutError:
        raise UpdateFailed("WebSocket timeout; retrying in 60s")
    except AuthError as e:
        raise ConfigEntryAuthFailed(str(e)) from e  # Triggers re-auth flow
```

**WebSocket reconnection best practice:**

```python
async def _reconnect_with_backoff(self, max_retries=5):
    """Exponential backoff: 1s, 2s, 4s, 8s, 16s"""
    for attempt in range(max_retries):
        try:
            await self.cairn_client.connect()
            logger.info("WebSocket reconnected")
            return True
        except Exception as e:
            wait = 2 ** attempt
            logger.warning(f"Reconnect failed ({attempt+1}/{max_retries}); retry in {wait}s: {e}")
            await asyncio.sleep(wait)
    
    raise UpdateFailed("WebSocket reconnection exhausted")
```

---

## 3. CONFIG FLOW + ENTITY LIFECYCLE

### 3.1 ConfigFlow: User Input (Host + Auth Token)

**Documentation:** [Config Flow Handler](https://developers.home-assistant.io/docs/config_entries_config_flow_handler/) [T1]

```python
import voluptuous as vol
from homeassistant import config_entries
from homeassistant.const import CONF_HOST, CONF_API_TOKEN

DOMAIN = "cairn"

class CairnConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    VERSION = 1
    
    async def async_step_user(self, user_input=None):
        """Handle user-initiated flow."""
        errors = {}
        
        if user_input is not None:
            # Validate credentials
            try:
                cairn = CairnClient(user_input[CONF_HOST], user_input[CONF_API_TOKEN])
                await cairn.async_authenticate()
            except AuthError:
                errors["base"] = "invalid_auth"
            except ConnectionError:
                errors["base"] = "cannot_connect"
            
            if not errors:
                # Create entry with validated data
                return self.async_create_entry(
                    title=f"Cairn @ {user_input[CONF_HOST]}",
                    data=user_input
                )
        
        return self.async_show_form(
            step_id="user",
            data_schema=vol.Schema({
                vol.Required(CONF_HOST): str,  # e.g., "cairn.local" or "192.168.1.100"
                vol.Required(CONF_API_TOKEN): str,
            }),
            errors=errors
        )
```

**Step method naming:** `async_step_user`, `async_step_init`, `async_step_discovery` (for mDNS discovery flows).

### 3.2 async_setup_entry & Platform Setup

**Documentation:** [Config Entries](https://developers.home-assistant.io/docs/config_entries_index/) [T1]

```python
# custom_components/cairn/__init__.py

async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up integration from a config entry."""
    hass.data.setdefault(DOMAIN, {})
    
    # 1. Authenticate and fetch camera config
    cairn = CairnClient(entry.data[CONF_HOST], entry.data[CONF_API_TOKEN])
    try:
        config = await cairn.async_get_config()
    except AuthError:
        raise ConfigEntryAuthFailed("Invalid API token")
    except ConnectionError:
        raise ConfigEntryNotReady("Cannot reach Cairn NVR")
    
    # 2. Store coordinator in hass.data
    coordinator = CairnEventCoordinator(hass, cairn)
    await coordinator.async_config_entry_first_refresh()
    
    hass.data[DOMAIN][entry.entry_id] = {
        "coordinator": coordinator,
        "config": config,
        "client": cairn,
    }
    
    # 3. Forward setup to platforms (binary_sensor, switch, etc.)
    await hass.config_entries.async_forward_entry_setups(entry, ["binary_sensor", "switch", "number"])
    
    return True

async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Unload config entry and clean up resources."""
    unload_ok = await hass.config_entries.async_unload_platforms(entry, ["binary_sensor", "switch", "number"])
    if unload_ok:
        coordinator = hass.data[DOMAIN][entry.entry_id]["coordinator"]
        await coordinator.async_shutdown()  # Stop WebSocket listener
        hass.data[DOMAIN].pop(entry.entry_id)
    return unload_ok
```

### 3.3 Device Registry: One Device Per Camera

**Documentation:** [Device Registry](https://developers.home-assistant.io/docs/device_registry_index/) [T1]

```python
from homeassistant.helpers import device_registry as dr
from homeassistant.helpers.entity import DeviceInfo

async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Create a device entry for each camera."""
    device_registry = dr.async_get(hass)
    cameras = config.get("cameras", [])
    
    for camera in cameras:
        device_registry.async_get_or_create(
            config_entry_id=entry.entry_id,
            identifiers={(DOMAIN, camera["id"])},  # Serial, MAC, or stable UUID
            connections={(dr.CONNECTION_NETWORK_MAC, camera.get("mac_address", ""))},
            manufacturer="Cairn",
            model=camera.get("model", "NVR"),
            name=camera["name"],
            sw_version=camera.get("firmware", "unknown"),
        )
    
    return True
```

### 3.4 Entity Linking via DeviceInfo & unique_id

```python
# custom_components/cairn/binary_sensor.py

async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry, async_add_entities):
    """Add motion/occupancy sensors for each camera."""
    coordinator = hass.data[DOMAIN][entry.entry_id]["coordinator"]
    config = hass.data[DOMAIN][entry.entry_id]["config"]
    
    entities = []
    for camera in config["cameras"]:
        entities.append(
            CairnMotionSensor(coordinator, camera["id"], camera["name"])
        )
    
    async_add_entities(entities)

class CairnMotionSensor(CoordinatorEntity, BinarySensorEntity):
    """Motion detection for a single camera."""
    
    _attr_should_poll = False
    _attr_device_class = BinarySensorDeviceClass.MOTION
    
    def __init__(self, coordinator, camera_id, camera_name):
        super().__init__(coordinator)
        self.camera_id = camera_id
        self.camera_name = camera_name
        self._attr_unique_id = f"cairn_motion_{camera_id}"
    
    @property
    def name(self) -> str:
        return f"{self.camera_name} Motion"
    
    @property
    def device_info(self) -> DeviceInfo:
        """Link to device via identifiers."""
        return DeviceInfo(
            identifiers={(DOMAIN, self.camera_id)},
            name=self.camera_name,
            manufacturer="Cairn",
        )
    
    @property
    def is_on(self) -> bool:
        """Motion detected?"""
        if self.coordinator.data:
            return self.coordinator.data.get(self.camera_id, {}).get("motion", False)
        return False
```

### 3.5 Binary Sensor Device Classes for Motion/Object Detection

**Documentation:** [Binary Sensor Entity](https://developers.home-assistant.io/docs/core/entity/binary-sensor/) [T1]

Available device classes from `homeassistant.components.binary_sensor.BinarySensorDeviceClass`:

- `MOTION` — Motion detected
- `OCCUPANCY` — Room occupied (higher-level than motion)
- `SOUND` — Sound/noise detected
- `PRESENCE` — Entity/person presence
- `DOOR`, `WINDOW` — Physical opening
- `LOCK` — Lock state
- `CONNECTIVITY` — Device online/offline
- `BATTERY` — Low battery
- `GAS`, `SMOKE`, `SAFETY`, `TAMPER` — Safety alerts
- Others: `POWER`, `PROBLEM`, `VIBRATION`

```python
class CairnMotionSensor(CoordinatorEntity, BinarySensorEntity):
    _attr_device_class = BinarySensorDeviceClass.MOTION

class CairnOccupancySensor(CoordinatorEntity, BinarySensorEntity):
    _attr_device_class = BinarySensorDeviceClass.OCCUPANCY

class CairnSoundDetectedSensor(CoordinatorEntity, BinarySensorEntity):
    _attr_device_class = BinarySensorDeviceClass.SOUND
```

### 3.6 Dynamic Entity Addition/Removal (Runtime Camera Config Changes)

**Pattern: Listen to coordinator data changes and sync entities.**

```python
# In async_setup_entry (binary_sensor platform)

async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry, async_add_entities):
    """Set up entities and manage dynamic updates."""
    coordinator = hass.data[DOMAIN][entry.entry_id]["coordinator"]
    entity_registry = er.async_get(hass)
    
    # Track existing entities per camera
    existing_entities = {}
    
    def _update_entities():
        """Called on coordinator update; add/remove entities as needed."""
        current_cameras = {cam["id"] for cam in coordinator.data.get("cameras", [])}
        existing_camera_ids = set(existing_entities.keys())
        
        # Add new cameras
        new_cameras = current_cameras - existing_camera_ids
        if new_cameras:
            new_entities = [
                CairnMotionSensor(coordinator, cam_id, coord_data["cameras"][cam_id]["name"])
                for cam_id in new_cameras
            ]
            async_add_entities(new_entities)
            for cam_id in new_cameras:
                existing_entities[cam_id] = True
        
        # Remove deleted cameras
        removed_cameras = existing_camera_ids - current_cameras
        for cam_id in removed_cameras:
            unique_id = f"cairn_motion_{cam_id}"
            entity_entry = entity_registry.async_get_entity_id(
                "binary_sensor", DOMAIN, unique_id
            )
            if entity_entry:
                entity_registry.async_remove(entity_entry)
            del existing_entities[cam_id]
    
    # Subscribe to coordinator updates
    coordinator.async_add_listener(_update_entities)
    _update_entities()  # Sync on first setup
```

**Entity Registry cleanup:**

```python
from homeassistant.helpers import entity_registry as er

# In __init__.py, optionally implement async_remove_config_entry_device:
async def async_remove_config_entry_device(
    hass: HomeAssistant, 
    config_entry: ConfigEntry, 
    device_entry: DeviceEntry
) -> bool:
    """Clean up entities linked to a removed device."""
    entity_registry = er.async_get(hass)
    for entity_entry in er.async_entries_for_device(entity_registry, device_entry.id):
        entity_registry.async_remove(entity_entry.entity_id)
    return True
```

### 3.7 Switch & Number Entities for Control

For NVR control toggles (e.g., enable/disable recording, adjust detection sensitivity):

```python
# custom_components/cairn/switch.py

from homeassistant.components.switch import SwitchEntity
from homeassistant.helpers.entity import EntityCategory

class CairnRecordingToggle(CoordinatorEntity, SwitchEntity):
    """Toggle recording for a camera."""
    _attr_should_poll = False
    _attr_entity_category = EntityCategory.CONFIG  # Config switch
    
    def __init__(self, coordinator, camera_id, camera_name):
        super().__init__(coordinator)
        self.camera_id = camera_id
        self.camera_name = camera_name
        self._attr_unique_id = f"cairn_recording_{camera_id}"
    
    @property
    def is_on(self) -> bool:
        return self.coordinator.data.get(self.camera_id, {}).get("recording_enabled", True)
    
    async def async_turn_on(self, **kwargs) -> None:
        await self.coordinator.cairn_client.async_set_recording(self.camera_id, True)
        self.coordinator.async_set_updated_data(self.coordinator.data)  # Refresh
    
    async def async_turn_off(self, **kwargs) -> None:
        await self.coordinator.cairn_client.async_set_recording(self.camera_id, False)
        self.coordinator.async_set_updated_data(self.coordinator.data)

# custom_components/cairn/number.py

from homeassistant.components.number import NumberEntity, NumberMode

class CairnMotionThreshold(CoordinatorEntity, NumberEntity):
    """Adjust motion detection sensitivity (0-100)."""
    _attr_should_poll = False
    _attr_native_step = 5
    _attr_native_min_value = 0
    _attr_native_max_value = 100
    _attr_mode = NumberMode.SLIDER
    
    def __init__(self, coordinator, camera_id, camera_name):
        super().__init__(coordinator)
        self.camera_id = camera_id
        self.camera_name = camera_name
        self._attr_unique_id = f"cairn_motion_threshold_{camera_id}"
    
    @property
    def native_value(self) -> float:
        return float(self.coordinator.data.get(self.camera_id, {}).get("motion_threshold", 50))
    
    async def async_set_native_value(self, value: float) -> None:
        await self.coordinator.cairn_client.async_set_motion_threshold(self.camera_id, int(value))
        self.coordinator.async_set_updated_data(self.coordinator.data)
```

---

## Summary: Key Takeaways for Cairn Integration

| Area | Pattern | Source |
|------|---------|--------|
| **Media Browser** | Implement `MediaSource` with `async_browse_media`, `async_resolve_media`; organize by date/camera/label hierarchy; proxy URLs through HA endpoint | [T1] developers.home-assistant.io/docs/core/platform/media_source |
| **Push Integration** | Custom coordinator wrapping WebSocket listener; use `async_set_updated_data()` on events; set `_attr_should_poll = False` on entities; call `async_write_ha_state()` for efficiency | [T1] developers.home-assistant.io/docs/integration_fetching_data |
| **Availability** | Use `CoordinatorEntity.available` (auto-managed) or override with socket connection state; raise `ConfigEntryAuthFailed` for auth retrigger | [T1] developers.home-assistant.io/docs/integration_fetching_data |
| **ConfigFlow** | `async_step_user()` with voluptuous schema for host + API token; validate before `async_create_entry()` | [T1] developers.home-assistant.io/docs/config_entries_config_flow_handler |
| **Devices** | `device_registry.async_get_or_create()` per camera with stable identifiers (ID, MAC); link entities via `DeviceInfo(identifiers=...)` and `unique_id` | [T1] developers.home-assistant.io/docs/device_registry_index |
| **Binary Sensors** | Use `BinarySensorDeviceClass.MOTION`, `OCCUPANCY`, `SOUND` for object detection; set `_attr_should_poll = False` | [T1] developers.home-assistant.io/docs/core/entity/binary-sensor |
| **Dynamic Entities** | Subscribe to coordinator updates; add new entities via `async_add_entities()`; remove via `entity_registry.async_remove()` on camera deletion | [T1] developers.home-assistant.io/docs/entity_registry_index |

---

## Sources

[T1] - Authoritative (HA Official Docs)

- [Media Source Platform](https://developers.home-assistant.io/docs/core/platform/media_source/)
- [Integration Fetching Data](https://developers.home-assistant.io/docs/integration_fetching_data/)
- [Config Flow Handler](https://developers.home-assistant.io/docs/config_entries_config_flow_handler/)
- [Device Registry](https://developers.home-assistant.io/docs/device_registry_index/)
- [Entity Registry](https://developers.home-assistant.io/docs/entity_registry_index/)
- [Binary Sensor Entity](https://developers.home-assistant.io/docs/core/entity/binary-sensor/)
- [Config Entries](https://developers.home-assistant.io/docs/config_entries_index/)
- [BrowseMediaSource Root Class (July 2026)](https://developers.home-assistant.io/blog/2026/05/20/browse-media-source-root-class/)
- [Media Source Search (July 2026)](https://developers.home-assistant.io/blog/2026/07/03/media-source-search/)
- [Device Registry Single Config Entry (July 2026)](https://developers.home-assistant.io/blog/2026/07/21/device-registry-single-config-entry/)

[T3] - Community / Reference Implementation

- [Frigate Media Source Implementation](https://github.com/blakeblackshear/frigate-hass-integration/blob/master/custom_components/frigate/media_source.py)
- [Frigate HA Integration Repository](https://github.com/blakeblackshear/frigate-hass-integration)
