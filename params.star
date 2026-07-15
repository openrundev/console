param("name", type=STRING, description="Name for the app", default="OpenRun Console")

param("enable_updates", type=BOOLEAN, description="Whether to enable write operations", default=False)

param("enable_container", type=BOOLEAN, description="Whether to enable container operations", default=False)

param("enable_config", type=BOOLEAN, description="Whether to enable config operations", default=False)

param("enable_all", type=BOOLEAN, description="Whether to enable everything : read and writes and container and config", default=False)

param("enable_builder", type=BOOLEAN, description="Whether to enable the AI app builder screens", default=False)

param("docs_url", type=STRING, description="Base URL for the documentation site, used for the help links", default="https://openrun.dev")
