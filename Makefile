FILE=skeleton

########
#   Directories
S_DIR=Source
B_DIR=Build
GLMDIR=/opt/homebrew/include
########
#   Output
EXEC=$(B_DIR)/$(FILE)

# default build settings
CC_OPTS=-c -pipe -Wall -Wno-switch -O3
LN_OPTS=-framework Metal -framework Foundation -framework CoreGraphics
CC=g++

########
#       SDL options
SDL_CFLAGS := $(shell sdl-config --cflags)
GLM_CFLAGS := -I$(GLMDIR)
SDL_LDFLAGS := $(shell sdl-config --libs)

########
#   This is the default action
all:Build


########
#   Object list
#
OBJ = $(B_DIR)/$(FILE).o $(B_DIR)/MetalRenderer.o


########
#   Objects
$(B_DIR)/$(FILE).o : $(S_DIR)/$(FILE).cpp $(S_DIR)/SDLauxiliary.h $(S_DIR)/TestModel.h
	$(CC) $(CC_OPTS) -DUSE_METAL -pthread -o $(B_DIR)/$(FILE).o $(S_DIR)/$(FILE).cpp $(SDL_CFLAGS) $(GLM_CFLAGS)


$(B_DIR)/MetalRenderer.o : $(S_DIR)/MetalRenderer.mm $(S_DIR)/MetalRenderer.h $(S_DIR)/TestModel.h
	clang++ -c -O3 -std=c++17 -fobjc-arc -o $(B_DIR)/MetalRenderer.o $(S_DIR)/MetalRenderer.mm -I$(GLMDIR) $(SDL_CFLAGS)

$(B_DIR)/raytracer.metallib : $(S_DIR)/raytracer.metal
	xcrun -sdk macosx metal -c $(S_DIR)/raytracer.metal -o $(B_DIR)/raytracer.air
	xcrun -sdk macosx metallib $(B_DIR)/raytracer.air -o $(B_DIR)/raytracer.metallib

########
#   Main build rule
Build : $(OBJ) $(B_DIR)/raytracer.metallib Makefile
	$(CC) $(LN_OPTS) -pthread -o $(EXEC) $(OBJ) $(SDL_LDFLAGS)


clean:
	rm -f $(B_DIR)/* 
