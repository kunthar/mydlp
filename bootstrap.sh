#!/bin/bash

git submodule init
git submodule update

(
	cd src/rest
	git submodule init
	git submodule update
)

autoreconf -f -i
