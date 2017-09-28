package gcs

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"sync"

	"cloud.google.com/go/storage"
)

// uploadFunc knows how to upload into an object
type uploadFunc func(obj *storage.ObjectHandle) error

// uploadToGCS uploads all of the data in the
// uploadTargets map to GCS in parallel. The map is
// keyed on GCS path under the bucket
func uploadToGCS(bucket *storage.BucketHandle, uploadTargets map[string]uploadFunc) error {
	errCh := make(chan error, len(uploadTargets))
	group := &sync.WaitGroup{}
	group.Add(len(uploadTargets))
	for dest, upload := range uploadTargets {
		obj := bucket.Object(dest)
		log.Printf("Queueing file for upload: %s\n", dest)
		go func(f uploadFunc, obj *storage.ObjectHandle) {
			defer group.Done()
			if err := f(obj); err != nil {
				errCh <- err
			}
		}(upload, obj)
	}
	group.Wait()
	close(errCh)
	if len(errCh) != 0 {
		var uploadErrors []error
		for err := range errCh {
			uploadErrors = append(uploadErrors, err)
		}
		return fmt.Errorf("encountered errors during upload: %v", uploadErrors)
	}

	return nil
}

// fileUpload returns an uploadFunc which copies all
// data from the file on disk to the GCS object
func fileUpload(file string) uploadFunc {
	return func(obj *storage.ObjectHandle) error {
		reader, err := os.Open(file)
		if err != nil {
			return err
		}

		defer reader.Close()
		return dataUpload(reader)(obj)
	}
}

// dataUpload returns an uploadFunc which copies all
// data from src reader into GCS
func dataUpload(src io.Reader) uploadFunc {
	return func(obj *storage.ObjectHandle) error {
		writer := obj.NewWriter(context.Background())
		defer writer.Close()

		_, err := io.Copy(writer, src)
		return err
	}
}
