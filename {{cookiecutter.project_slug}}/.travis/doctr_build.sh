# This script is called from travis.yml for the "Docs" job
#
# Actual deployment will only happen if the TRAVIS environment variable is set.
# It is possible to run this script locally (outside of Travis) for a test of
# artifact building by setting only the TRAVIS_TAG variable, e.g.:
#
#   TRAVIS_TAG=v1.0.0-rc1 sh .travis/doctr_build.sh
#
# This will leave artifacts in the docs/_build/artifacts folder.

echo "# DOCTR - deploy documentation"

{%- if cookiecutter.doctr_artifact_hosting == "bintray" %}

if [ ! -z "$TRAVIS" ]; then
    echo "## Check bintray status"
    # We *always* do this check: we don't just want to find out about
    # authentication errors when making a release
    if [ -z "$BINTRAY_USER" ]; then
        echo "BINTRAY_USER must be set" && sync && exit 1
    fi
    if [ -z "$BINTRAY_TOKEN" ]; then
        echo "BINTRAY_TOKEN must be set" && sync && exit 1
    fi
    if [ -z "$BINTRAY_PACKAGE" ]; then
        echo "BINTRAY_PACKAGE must be set" && sync && exit 1
    fi
    url="https://api.bintray.com/repos/$BINTRAY_SUBJECT/$BINTRAY_REPO/packages"
    response=$(curl --user "$BINTRAY_USER:$BINTRAY_TOKEN" "$url")
    if [ -z "${response##*$BINTRAY_PACKAGE*}" ]; then
        echo "Bintray OK: $url -> $response"
    else
        echo "Error: Cannot find $BINTRAY_PACKAGE in $url: $response" && sync && exit 1
    fi
fi

{%- endif %}

{%- if cookiecutter.doctr_artifact_hosting == "gh-releases" %}

if [ ! -z "$TRAVIS" ]; then
    echo "## Check GITHUB_TOKEN status"
    # We *always* do this check: we don't just want to find out about
    # authentication errors when making a release
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "GITHIB_TOKEN must be set" && sync && exit 1
    fi
    GH_AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
    url="https://api.github.com/repos/$TRAVIS_REPO_SLUG"
    curl -o /dev/null -sH "$AUTH" "$url" || { echo "Error: Invalid repo, token or network issue!";  sync; exit 1; }
fi

{%- endif %}

echo "## Generate main html documentation"
tox -e docs

if [ ! -z "$TRAVIS_TAG" ]; then

    echo "Deploying as TAG $TRAVIS_TAG"

    echo "## Generate documentation downloads"
    # We generate documentation downloads only for tags (which are assumed to
    # correspond to releases). Otherwise, we'd quickly fill up git with binary
    # artifacts for every single push.
    mkdir docs/_build/artifacts

    # We build the documentation artifacts in the temporary
    # docs/_build/artifacts. These are then deployed to the cloud, and a
    # _download file is written to the main html documentation containing links
    # to all the artifacts. The find_downloads function in doctr_post_process
    # will then later transfer those links into versions.json

    echo "### [zip]"
    cp -r docs/_build/html "docs/_build/{{ cookiecutter.project_slug }}-$TRAVIS_TAG"
    cd docs/_build || exit 1
    zip -r "{{ cookiecutter.project_slug }}-$TRAVIS_TAG.zip" "{{ cookiecutter.project_slug }}-$TRAVIS_TAG"
    rm -rf "{{ cookiecutter.project_slug }}-$TRAVIS_TAG"
    cd ../../ || exit 1
    mv "docs/_build/{{ cookiecutter.project_slug }}-$TRAVIS_TAG.zip" docs/_build/artifacts/

    {%- if cookiecutter.travis_texlive == 'y' %}

    echo "### [pdf]"
    tox -e docs -- -b latex _build/latex
    tox -e run-cmd -- python docs/build_pdf.py docs/_build/latex/*.tex
    echo "finished latex compilation"
    mv docs/_build/latex/*.pdf "docs/_build/artifacts/{{ cookiecutter.project_slug }}-$TRAVIS_TAG.pdf"

    {%- endif %}

    echo "### [epub]"
    tox -e docs -- -b epub _build/epub
    mv docs/_build/epub/*.epub "docs/_build/artifacts/{{ cookiecutter.project_slug }}-$TRAVIS_TAG.epub"

    if [ ! -z "$TRAVIS" ]; then

        {%- if cookiecutter.doctr_artifact_hosting == "gh-releases" %}

        # upload as release assets
        # adapted from https://gist.github.com/stefanbuck/ce788fee19ab6eb0b4447a85fc99f447
        # This relies on the encrypted $GITHUB_TOKEN variable in .travis.yml
        url="https://api.github.com/repos/$TRAVIS_REPO_SLUG/releases"
        echo "Make release from tag $TRAVIS_TAG: $url"
        API_JSON=$(printf '{"tag_name": "%s","target_commitish": "master","name": "%s","body": "Release %s","draft": false,"prerelease": false}' "$TRAVIS_TAG" "$TRAVIS_TAG" "$TRAVIS_TAG")
        echo "submitted data = $API_JSON"
        response=$(curl --data "$API_JSON" --header "$GH_AUTH_HEADER" "$url")
        echo "Release response: $response"
        url="https://api.github.com/repos/$TRAVIS_REPO_SLUG/releases/tags/$TRAVIS_TAG"
        echo "verify $url"
        response=$(curl --silent --header "$GH_AUTH_HEADER" "$url")
        echo "$response"
        eval $(echo "$response" | grep -m 1 "id.:" | grep -w id | tr : = | tr -cd '[[:alnum:]]=')
        echo "id = $id"
        for filename in docs/_build/artifacts/*; do
            url="https://uploads.github.com/repos/$TRAVIS_REPO_SLUG/releases/$id/assets?name=$(basename $filename)"
            echo "Uploading $filename as release asset to $url"
            response=$(curl "$GITHUB_OAUTH_BASIC" --data-binary @"$filename" --header "$GH_AUTH_HEADER" --header "Content-Type: application/octet-stream" "$url")
            echo "Uploaded $filename: $response"
            echo $response | python -c 'import json,sys;print(json.load(sys.stdin)["browser_download_url"])' >> docs/_build/html/_downloads
        done

        {%- endif %}

        {%- if cookiecutter.doctr_artifact_hosting == "bintray" %}

        # upload to bintray
        # Depends on $BINTRAY_USER, $BINTRAY_SUBJECT, $BINTRAY_REPO, $BINTRAY_PACKAGE, and secret $BINTRAY_TOKEN from .travis.yml
        echo "Upload artifacts to bintray"
        for filename in docs/_build/artifacts/*; do
            url="https://api.bintray.com/content/$BINTRAY_SUBJECT/$BINTRAY_REPO/$BINTRAY_PACKAGE/$TRAVIS_TAG/$(basename $filename)"
            echo "Uploading $filename artifact to $url"
            response=$(curl --upload-file "$filename" --user "$BINTRAY_USER:$BINTRAY_TOKEN" "$url")
            if [ -z "${response##*success*}" ]; then
                echo "Uploaded $filename: $response"
                echo "https://dl.bintray.com/$BINTRAY_SUBJECT/$BINTRAY_REPO/$(basename $filename)" >> docs/_build/html/_downloads
            else
                echo "Error: Failed to upload $filename: $response" && sync && exit 1
            fi
        done
        echo "Publishing release on bintray"
        url="https://api.bintray.com/content/$BINTRAY_SUBJECT/$BINTRAY_REPO/$BINTRAY_PACKAGE/$TRAVIS_TAG/publish"
        response=$(curl --request POST --user "$BINTRAY_USER:$BINTRAY_TOKEN" "$url")
        if [ -z "${response##*files*}" ]; then
            echo "Finished bintray release : $response"
        else
            echo "Error: Failed publish release on bintray: $response" && sync && exit 1
        fi

        {%- endif %}

        {%- if cookiecutter.doctr_artifact_hosting == "gh-pages" %}

        echo "Copy artifacts to downloads folder"
        mkdir docs/_build/html/downloads
        for filename in docs/_build/artifacts/*; do
            echo "Copy $filename"
            cp "$filename" docs/_build/html/downloads/
            echo "$TRAVIS_TAG/downloads/$(basename $filename)" >> docs/_build/html/_downloads
        done
        echo "Finished copying artifacts"

        {%- endif %}

        echo "docs/_build/html/_downloads:"
        cat docs/_build/html/_downloads

        rm -rf docs/_build/artifacts

    fi

elif [ ! -z "$TRAVIS_BRANCH" ]; then

    echo "Deploying as BRANCH $TRAVIS_BRANCH"

else

    echo "At least one of TRAVIS_TAG and TRAVIS_BRANCH must be set"
    sync
    exit 1

fi

# Deploy
if [ ! -z "$TRAVIS" ]; then
    echo "## pip install doctr"
    python -m pip install doctr
    echo "## doctr deploy"
    if [ ! -z "$TRAVIS_TAG" ]; then
        DEPLOY_DIR="$TRAVIS_TAG"
    else
        DEPLOY_DIR="$TRAVIS_BRANCH"
    fi
    python -m doctr deploy --key-path docs/doctr_deploy_key.enc \
        --command="git show $TRAVIS_COMMIT:.travis/doctr_post_process.py > post_process.py && git show $TRAVIS_COMMIT:.travis/versions.py > versions.py && python post_process.py" \
        --built-docs docs/_build/html --no-require-master --build-tags "$DEPLOY_DIR"
fi

echo "# DOCTR - DONE"
