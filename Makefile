D2_SRC_DIR := diagrams
D2_OUT_DIR := static/img/diagrams
D2_FILES   := $(wildcard $(D2_SRC_DIR)/*.d2)
D2_SVGS    := $(patsubst $(D2_SRC_DIR)/%.d2,$(D2_OUT_DIR)/%.svg,$(D2_FILES))

D2_FONT    := diagrams/fonts/SourceCodePro-Regular.ttf
D2_FONT_IT := diagrams/fonts/SourceCodePro-Italic.ttf
D2_FLAGS   := --layout elk --theme 100 --pad 40 \
	--font-regular $(D2_FONT) \
	--font-bold $(D2_FONT) \
	--font-semibold $(D2_FONT) \
	--font-italic $(D2_FONT_IT)

# Default: render all diagrams
diagrams: $(D2_SVGS)

$(D2_OUT_DIR)/%.svg: $(D2_SRC_DIR)/%.d2 Makefile
	d2 $(D2_FLAGS) $< $@

# Watch a single diagram for live iteration:
#   make watch D=my-diagram
watch:
	@test -n "$(D)" || { echo "Usage: make watch D=<name>  (without .d2 extension)"; exit 1; }
	d2 --watch $(D2_FLAGS) $(D2_SRC_DIR)/$(D).d2 $(D2_OUT_DIR)/$(D).svg

# List all diagrams and their render status
list:
	@for f in $(D2_SRC_DIR)/*.d2; do \
		name=$$(basename "$$f" .d2); \
		if [ -f "$(D2_OUT_DIR)/$$name.svg" ]; then \
			echo "  $$name  [rendered]"; \
		else \
			echo "  $$name  [not rendered]"; \
		fi; \
	done

# Remove all rendered diagrams
clean-diagrams:
	rm -f $(D2_OUT_DIR)/*.svg

# Watch all diagrams for changes and re-render
watch-all:
	@echo "Watching $(D2_SRC_DIR)/ for changes..."
	@while true; do \
		make diagrams 2>&1 | grep -v "Nothing to be done"; \
		find $(D2_SRC_DIR) -name '*.d2' | entr -d -p make diagrams; \
	done

.PHONY: diagrams watch watch-all list clean-diagrams
