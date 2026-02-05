# RetroDECK Changelog: Remote ROMs & WebDAV Integration

## Overview
This changelog documents the introduction of Remote ROMs and WebDAV functionalities into the RetroDECK project. It details the new features, affected files, and architectural considerations, serving as a reference for future development and audits.

---

## New Functionalities

### 1. Remote ROMs Support
- **Purpose:** Enable users to access and manage ROMs stored on remote servers, expanding the flexibility and scalability of game library management.
- **Key Features:**
  - Seamless integration of remote ROM sources into the RetroDECK ecosystem.
  - Support for mounting, listing, and accessing ROMs over network protocols.

### 2. WebDAV Integration
- **Purpose:** Provide native support for the WebDAV protocol, allowing RetroDECK to connect to a wide range of cloud storage providers and self-hosted solutions.
- **Key Features:**
  - Authentication and session management for WebDAV endpoints.
  - File operations (list, download, mount) over WebDAV.
  - User configuration options for WebDAV servers.

### 3. Subfunctions and Utilities
- **Purpose:** Modularize remote ROMs and WebDAV logic for maintainability and extensibility.
- **Key Features:**
  - Helper functions for connection handling, error management, and user prompts.
  - Abstraction layers to support future remote storage protocols.

---

## Affected Files & Changes

### dialogs.sh
- **Change:** Added a new menu for remote ROMs management.
- **Details:**
  - User interface elements for selecting, mounting, and managing remote ROM sources.
  - Integration with backend logic for remote operations.

### retrodeck.json
- **Change:** Added new configuration options.
- **Details:**
  - User-defined settings for remote ROMs and WebDAV endpoints.
  - Options for authentication, server URLs, and feature toggles.

### remote_roms.sh
- **Change:** New file created.
- **Details:**
  - Core logic for remote ROMs and WebDAV operations.
  - Functions for mounting, listing, and managing remote ROMs.
  - Error handling and logging for remote operations.

### run_game.sh
- **Change:** Logic for handling remote paths added.
- **Details:**
  - Detection and processing of remote ROM paths.
  - Integration with remote_roms.sh for seamless game launching from remote sources.

---

## Architectural Considerations
- **Modularity:** Remote ROMs and WebDAV logic are encapsulated in dedicated scripts for maintainability.
- **Extensibility:** The architecture allows for future support of additional remote storage protocols.
- **User Experience:** Dialogs and configuration options are designed for intuitive user interaction.
- **Security:** Authentication and error handling are implemented to ensure safe remote operations.

---

## Summary
This changelog establishes the baseline for all functionalities related to Remote ROMs and WebDAV integration in RetroDECK. It provides a clear record of the architectural approach, affected files, and user-facing features, supporting both technical documentation and future development planning.
